import AppKit
import Foundation

@MainActor
class IdleManager {
    static let shared = IdleManager()

    private var suspendedPIDs = Set<pid_t>()

    func start() {
        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleWorkspaces()
            }
        }
    }

    func checkIdleWorkspaces() {
        let now = Date()
        let configuredMinutes = max(1, Persistence.loadPreferences().idleTimeoutMinutes)
        let timeout: TimeInterval = TimeInterval(configuredMinutes * 60)

        let allSessionWindows = WindowTracker.shared.sessionWindows.values
        let activeWsId = WorkspaceManager.shared.activeWorkspaceId

        var activePIDs = Set<pid_t>()
        var targetToFreezePIDs = Set<pid_t>()
        var targetToResumePIDs = Set<pid_t>()

        if let activeId = activeWsId,
            let activeWs = WorkspaceManager.shared.workspaces.first(where: { $0.id == activeId })
        {
            for ref in activeWs.assignedWindows {
                if let win = allSessionWindows.first(where: { $0.id == ref.id }) {
                    activePIDs.insert(win.pid)
                    targetToResumePIDs.insert(win.pid)
                }
            }
        }

        for ws in WorkspaceManager.shared.workspaces {
            if ws.id == activeWsId { continue }

            let isExpired =
                ws.idleOptimization && (now.timeIntervalSince(ws.lastActiveAt) > timeout)

            for ref in ws.assignedWindows {
                if let win = allSessionWindows.first(where: { $0.id == ref.id }) {
                    if isExpired {
                        targetToFreezePIDs.insert(win.pid)
                    } else {
                        targetToResumePIDs.insert(win.pid)
                    }
                }
            }
        }

        targetToFreezePIDs.subtract(activePIDs)

        let safeResume = targetToResumePIDs.filter { !isSystemApp(pid: $0) }
        let safeFreeze = targetToFreezePIDs.filter {
            guard !isSystemApp(pid: $0) else { return false }
            guard let app = NSRunningApplication(processIdentifier: $0) else { return false }
            return app.isHidden
        }

        for pid in safeResume {
            if suspendedPIDs.contains(pid) {
                if kill(pid, SIGCONT) == 0 {
                    suspendedPIDs.remove(pid)
                    TelemetryManager.shared.record(
                        event: "process_resumed",
                        level: "debug",
                        metadata: ["pid": String(pid)]
                    )
                } else {
                    TelemetryManager.shared.record(
                        event: "process_resume_failed",
                        level: "warning",
                        metadata: ["pid": String(pid)]
                    )
                }
            }
        }

        for pid in safeFreeze {
            if !suspendedPIDs.contains(pid) {
                if kill(pid, SIGSTOP) == 0 {
                    suspendedPIDs.insert(pid)
                    TelemetryManager.shared.record(
                        event: "process_frozen",
                        level: "debug",
                        metadata: ["pid": String(pid)]
                    )
                } else {
                    TelemetryManager.shared.record(
                        event: "process_freeze_failed",
                        level: "warning",
                        metadata: ["pid": String(pid)]
                    )
                }
            }
        }
    }

    private func isSystemApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        let excludedBundles = [
            "com.apple.finder",
            "com.apple.dock",
            "com.apple.systemuiserver",
            "com.apple.loginwindow",
        ]
        return excludedBundles.contains(bundle) || bundle.contains("deks")
    }
}
