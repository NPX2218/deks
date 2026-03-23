import AppKit
@preconcurrency import ApplicationServices
import Foundation

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
    private var isPermissionAlertVisible = false
    private var didRequestSystemPrompt = false
    private var permissionPollAttempts = 0
    private var hasShownDelayedPermissionHint = false

    private let permissionPollInterval: TimeInterval = 1.0
    private let delayedHintAttemptThreshold = 15

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always show the app in the menu bar immediately so startup feels responsive.
        MenuBarManager.shared.setup()
        requestPermissionsAndStart()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !didSetupApp {
            requestPermissionsAndStart()
        }
    }

    private func requestPermissionsAndStart() {
        let isTrusted: Bool
        if didRequestSystemPrompt {
            isTrusted = AXIsProcessTrusted()
        } else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            isTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
            didRequestSystemPrompt = true
        }

        if isTrusted {
            completeSetupIfNeeded()
        } else {
            beginPermissionPolling()
            if !isPermissionAlertVisible {
                showAccessibilityAlert()
            }
        }
    }

    private func beginPermissionPolling() {
        if permissionPollTimer != nil { return }
        permissionPollTimer = Timer.scheduledTimer(
            withTimeInterval: permissionPollInterval, repeats: true
        ) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.permissionPollTimer?.invalidate()
                    self.permissionPollTimer = nil
                    self.permissionPollAttempts = 0
                    self.hasShownDelayedPermissionHint = false
                    self.completeSetupIfNeeded()
                } else {
                    self.permissionPollAttempts += 1
                    if self.permissionPollAttempts >= self.delayedHintAttemptThreshold,
                        !self.hasShownDelayedPermissionHint,
                        !self.isPermissionAlertVisible
                    {
                        self.hasShownDelayedPermissionHint = true
                        self.showDelayedPermissionHint()
                    }
                }
            }
        }
    }

    private func showAccessibilityAlert() {
        isPermissionAlertVisible = true
        defer { isPermissionAlertVisible = false }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText =
            "Deks needs Accessibility access to manage windows.\n\nEnable Deks in System Settings > Privacy & Security > Accessibility, then return here."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "I've Enabled It")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAccessibilitySettings()
            beginPermissionPolling()
        case .alertSecondButtonReturn:
            handlePermissionRecheck()
        default:
            NSApp.terminate(nil)
        }
    }

    private func handlePermissionRecheck() {
        if AXIsProcessTrusted() {
            completeSetupIfNeeded()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Still Waiting for Permission"
        alert.informativeText =
            "Deks still cannot access Accessibility APIs yet.\n\nIf you just enabled it, macOS sometimes takes a few seconds to apply changes."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Keep Waiting")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAccessibilitySettings()
            beginPermissionPolling()
        case .alertSecondButtonReturn:
            beginPermissionPolling()
        default:
            NSApp.terminate(nil)
        }
    }

    private func showDelayedPermissionHint() {
        isPermissionAlertVisible = true
        defer { isPermissionAlertVisible = false }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Permission Not Applied Yet"
        alert.informativeText =
            "macOS is still reporting that Deks is blocked from Accessibility APIs.\n\nIf this keeps happening: remove Deks from Accessibility, add it again, then reopen Deks."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Re-check")
        alert.addButton(withTitle: "Quit")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAccessibilitySettings()
        case .alertSecondButtonReturn:
            handlePermissionRecheck()
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
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        permissionPollAttempts = 0
        hasShownDelayedPermissionHint = false
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
