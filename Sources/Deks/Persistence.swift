import Foundation
import AppKit

class Persistence {
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
}
