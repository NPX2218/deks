import AppKit
import Foundation

class Persistence {
    static let defaultPreferences = Preferences(
        defaultNewWindowBehavior: .autoAssignToActive,
        idleTimeoutMinutes: 5,
        showLogoInMenuBar: false,
        developerDiagnosticsEnabled: false,
        workspaceSwitchModifier: .control
    )

    static var appSupportDir: URL {
        let fileManager = FileManager.default
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deks")
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func workspacesFileUrl() -> URL {
        return appSupportDir.appendingPathComponent("workspaces.json")
    }

    static func preferencesFileUrl() -> URL {
        return appSupportDir.appendingPathComponent("preferences.json")
    }

    static func appStateFileUrl() -> URL {
        return appSupportDir.appendingPathComponent("app-state.json")
    }

    static func loadPreferences() -> Preferences {
        let url = preferencesFileUrl()
        guard let data = try? Data(contentsOf: url),
            let prefs = try? JSONDecoder().decode(Preferences.self, from: data)
        else {
            savePreferences(defaultPreferences)
            UserDefaults.standard.set(
                defaultPreferences.developerDiagnosticsEnabled,
                forKey: "deks.devLogs"
            )
            return defaultPreferences
        }
        UserDefaults.standard.set(prefs.developerDiagnosticsEnabled, forKey: "deks.devLogs")
        return prefs
    }

    static func savePreferences(_ preferences: Preferences) {
        let url = preferencesFileUrl()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(preferences) {
            try? data.write(to: url)
        }
    }
}
