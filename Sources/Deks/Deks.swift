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
    private var didSetupApp = false
    private var permissionPollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestPermissionsAndStart()
    }

    private func requestPermissionsAndStart() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)

        if isTrusted {
            completeSetupIfNeeded()
        } else {
            beginPermissionPolling()
            showAccessibilityAlert()
        }
    }

    private func beginPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.permissionPollTimer?.invalidate()
                self.permissionPollTimer = nil
                self.completeSetupIfNeeded()
            }
        }
    }

    private func showAccessibilityAlert() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "Deks needs Accessibility access to manage windows.\n\nEnable Deks in System Settings > Privacy & Security > Accessibility, then return here."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "I've Enabled It")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAccessibilitySettings()
            beginPermissionPolling()
        case .alertSecondButtonReturn:
            if AXIsProcessTrusted() {
                completeSetupIfNeeded()
            } else {
                showAccessibilityAlert()
            }
        default:
            NSApp.terminate(nil)
        }
    }

    private func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func completeSetupIfNeeded() {
        guard !didSetupApp else { return }
        didSetupApp = true
        print("Accessibility permissions granted.")
        setupApp()
    }

    private func setupApp() {
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
