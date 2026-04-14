import Foundation

final class TelemetryManager: @unchecked Sendable {
    static let shared = TelemetryManager()

    private let queue = DispatchQueue(label: "com.deks.telemetry", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private struct SessionState: Codable {
        var launchedAt: Date
        var cleanShutdown: Bool
    }

    private init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

    private func logsDirURL() -> URL {
        let base = Persistence.appSupportDir
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func eventsFileURL() -> URL {
        logsDirURL().appendingPathComponent("events.log")
    }

    private func sessionFileURL() -> URL {
        logsDirURL().appendingPathComponent("session-state.json")
    }

    func markLaunch() {
        queue.async {
            let sessionURL = self.sessionFileURL()
            if let data = try? Data(contentsOf: sessionURL),
                let previous = try? JSONDecoder().decode(SessionState.self, from: data),
                !previous.cleanShutdown
            {
                self.recordSync(
                    event: "unclean_shutdown_detected",
                    level: "warning",
                    metadata: [
                        "previousLaunch": self.isoFormatter.string(from: previous.launchedAt)
                    ]
                )
            }

            let current = SessionState(launchedAt: Date(), cleanShutdown: false)
            if let encoded = try? JSONEncoder().encode(current) {
                try? encoded.write(to: sessionURL)
            }

            self.recordSync(event: "app_launch", metadata: ["bundlePath": Bundle.main.bundlePath])
        }
    }

    func markCleanShutdown() {
        queue.async {
            let current = SessionState(launchedAt: Date(), cleanShutdown: true)
            if let encoded = try? JSONEncoder().encode(current) {
                try? encoded.write(to: self.sessionFileURL())
            }
            self.recordSync(event: "app_shutdown")
        }
    }

    func record(event: String, level: String = "info", metadata: [String: String] = [:]) {
        queue.async {
            self.writeLine(event: event, level: level, metadata: metadata)
        }
    }

    func recordSync(event: String, level: String = "info", metadata: [String: String] = [:]) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            writeLine(event: event, level: level, metadata: metadata)
        } else {
            queue.sync {
                self.writeLine(event: event, level: level, metadata: metadata)
            }
        }
    }

    private func writeLine(event: String, level: String, metadata: [String: String]) {
        var payload: [String: String] = [
            "time": isoFormatter.string(from: Date()),
            "level": level,
            "event": event,
        ]
        for (k, v) in metadata {
            payload[k] = v
        }

        guard let lineData = try? JSONSerialization.data(withJSONObject: payload, options: []),
            var line = String(data: lineData, encoding: .utf8)
        else { return }

        line.append("\n")
        let url = eventsFileURL()
        let data = Data(line.utf8)

        // Create the file if it doesn't exist, then append via FileHandle so we
        // never overwrite prior events.
        if !FileManager.default.fileExists(atPath: url.path) {
            try? data.write(to: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
