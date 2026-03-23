import Foundation
import AppKit
@preconcurrency import ApplicationServices

@main
@MainActor
struct DeksApp {
    static func main() {
        let app = NSApplication.shared
        // Configure it to run as a standard UI app, not a background daemon initially
        // but we may want it to be a menu bar app (.accessory). 
        // For MVP testing, let's keep it standard or accessory.
        app.setActivationPolicy(.accessory)
        
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        checkPermissionsAndStart()
    }
    
    func checkPermissionsAndStart() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if isTrusted {
            print("Accessibility permissions granted.")
            setupApp()
        } else {
            print("Accessibility permissions not granted. Please allow in System Settings.")
            // Give user time/prompt, but here we can just loop or prompt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                self.checkPermissionsAndStart()
            }
        }
    }
    
    func setupApp() {
        if WorkspaceManager.shared.workspaces.isEmpty {
            let defaultWs = WorkspaceManager.shared.createWorkspace(name: "Default", color: .blue)
            WorkspaceManager.shared.activeWorkspaceId = defaultWs.id
            print("Created Default workspace.")
        } else {
            print("Loaded workspaces: \(WorkspaceManager.shared.workspaces.count)")
        }
        
        MenuBarManager.shared.setup()
        IdleManager.shared.start()
        WorkspaceManager.shared.startAutoAssigner()
        
        // Reconcile anything missing right at startup onto active Workspace
        WorkspaceManager.shared.reconcileUnassignedWindows()
        
        let windows = WindowTracker.shared.discoverWindows()
        print("Discovered \(windows.count) visible windows on screen.")
        for win in windows {
            print("  - \(win.appName): \(win.title)")
        }
    }
}
