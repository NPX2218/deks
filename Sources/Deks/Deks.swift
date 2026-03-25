import AppKit
@preconcurrency import ApplicationServices
import Foundation

extension Notification.Name {
    static let requestPermissionWalkthrough = Notification.Name("requestPermissionWalkthrough")
}

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
    private var didRequestPermissionPromptThisLaunch = false
    private var permissionWindowController: PermissionOnboardingWindowController?
    private let onboardingCompleteKey = "deks.onboardingComplete"

    private let permissionPollInterval: TimeInterval = 1.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        TelemetryManager.shared.markLaunch()
        // Always show the app in the menu bar immediately so startup feels responsive.
        MenuBarManager.shared.setup()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePermissionWalkthroughRequest),
            name: .requestPermissionWalkthrough,
            object: nil
        )
        requestPermissionsAndStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        WorkspaceManager.shared.persistActiveWorkspaceWindowOrder()
        NotificationCenter.default.removeObserver(self)
        TelemetryManager.shared.markCleanShutdown()
    }

    @objc private func handlePermissionWalkthroughRequest() {
        guard !didSetupApp else { return }
        ConfigPanelController.orderOutVisibleWindowIfInitialized()
        requestSystemPermissionPrompt()
        openAccessibilitySettings()
        beginPermissionPolling()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if !didSetupApp {
            requestPermissionsAndStart()
        }
    }

    private func requestPermissionsAndStart() {
        let isTrusted = AXIsProcessTrusted()
        TelemetryManager.shared.recordSync(
            event: "accessibility_check",
            metadata: ["trusted": isTrusted ? "true" : "false"]
        )

        if isTrusted {
            completeSetupIfNeeded()
        } else {
            UserDefaults.standard.set(false, forKey: onboardingCompleteKey)
            if !didRequestPermissionPromptThisLaunch {
                didRequestPermissionPromptThisLaunch = true
                requestSystemPermissionPrompt()
            }
            beginPermissionPolling()
        }
    }

    private func requestSystemPermissionPrompt() {
        TelemetryManager.shared.recordSync(
            event: "native_permission_prompt_requested", level: "debug")

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        beginPermissionPolling()
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
                    self.completeSetupIfNeeded()
                }
            }
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
        UserDefaults.standard.set(true, forKey: onboardingCompleteKey)
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        permissionWindowController?.closeWindow()
        permissionWindowController = nil
        WorkspaceManager.shared.setManualOrganizationMode(false)
        TelemetryManager.shared.record(event: "accessibility_permissions_granted")
        setupApp()
        showPostPermissionAssignmentHint()
    }

    private func relaunchApp() {
        let appPath = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appPath]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func setupApp() {
        if WorkspaceManager.shared.workspaces.isEmpty {
            let defaultWs = WorkspaceManager.shared.createWorkspace(name: "Default", color: .blue)
            WorkspaceManager.shared.activeWorkspaceId = defaultWs.id
            TelemetryManager.shared.record(event: "default_workspace_created")
        } else {
            TelemetryManager.shared.record(
                event: "workspaces_loaded",
                metadata: ["count": String(WorkspaceManager.shared.workspaces.count)]
            )
        }

        IdleManager.shared.start()
        WorkspaceManager.shared.startAutoAssigner()

        // Move heavy window discovery to background to let UI appear immediately
        Task {
            let seededCount = WorkspaceManager.shared.seedActiveWorkspaceFromSessionIfNeeded()
            if seededCount > 0 {
                TelemetryManager.shared.record(
                    event: "workspace_seeded",
                    metadata: ["windowCount": String(seededCount)]
                )
            }

            // Discover first, then rebalance visibility without reassigning everything to active.
            WindowTracker.shared.synchronizeSession(workspaces: WorkspaceManager.shared.workspaces)
            WorkspaceManager.shared.startStartupRebalance()

            let windows = WindowTracker.shared.discoverWindows()
            TelemetryManager.shared.record(
                event: "windows_discovered",
                metadata: ["count": String(windows.count)]
            )
        }
    }

    private func showPostPermissionAssignmentHint() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Setup complete"
            alert.informativeText =
                "Now open the Deks menu bar popup and quickly reorganize your windows into the right workspaces. This makes switching behavior predictable from the start."
            alert.addButton(withTitle: "Got it")

            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

@MainActor
final class PermissionOnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let statusTitleLabel = NSTextField(labelWithString: "")
    private let statusDetailLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")

    private let onRequestPermission: () -> Void
    private let onOpenSettings: () -> Void
    private let onCheckAgain: () -> Void
    private let onRelaunch: () -> Void
    private let onQuit: () -> Void

    init(
        onRequestPermission: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCheckAgain: @escaping () -> Void,
        onRelaunch: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onRequestPermission = onRequestPermission
        self.onOpenSettings = onOpenSettings
        self.onCheckAgain = onCheckAgain
        self.onRelaunch = onRelaunch
        self.onQuit = onQuit

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Finish Deks Setup"
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
        window.delegate = self

        configureUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureUI() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Accessibility Permission Required")
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)

        statusTitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusTitleLabel.textColor = .labelColor

        statusDetailLabel.font = .systemFont(ofSize: 12)
        statusDetailLabel.textColor = .secondaryLabelColor
        statusDetailLabel.lineBreakMode = .byWordWrapping
        statusDetailLabel.maximumNumberOfLines = 0

        contextLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        contextLabel.textColor = .tertiaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingMiddle

        let stepOne = NSTextField(labelWithString: "1. Click Request Permission")
        let stepTwo = NSTextField(labelWithString: "2. Turn on Deks in Accessibility settings")
        let stepThree = NSTextField(labelWithString: "3. Return and click Check Again")
        [stepOne, stepTwo, stepThree].forEach {
            $0.font = .systemFont(ofSize: 12, weight: .medium)
            $0.textColor = .secondaryLabelColor
        }

        let requestButton = NSButton(
            title: "Request Permission", target: self, action: #selector(requestPermissionPressed))
        requestButton.keyEquivalent = "\r"

        let openButton = NSButton(
            title: "Open Accessibility Settings", target: self,
            action: #selector(openSettingsPressed))

        let checkButton = NSButton(
            title: "Check Again", target: self, action: #selector(checkAgainPressed))
        let relaunchButton = NSButton(
            title: "Relaunch Deks", target: self, action: #selector(relaunchPressed))
        let deleteButton = NSButton(
            title: "Delete Deks", target: self, action: #selector(deletePressed))
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitPressed))

        let buttonStack = NSStackView(views: [
            requestButton, openButton, checkButton, relaunchButton, deleteButton, quitButton,
        ])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillProportionally

        let root = NSStackView(views: [
            titleLabel, statusTitleLabel, statusDetailLabel, stepOne, stepTwo, stepThree,
            contextLabel,
            buttonStack,
        ])
        root.orientation = .vertical
        root.spacing = 10
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
        ])
    }

    func updateStatus(title: String, detail: String) {
        statusTitleLabel.stringValue = title
        statusDetailLabel.stringValue = detail
    }

    func updateContext(bundlePath: String) {
        contextLabel.stringValue = "Current app path: \(bundlePath)"
    }

    func closeWindow() {
        window?.orderOut(nil)
    }

    @objc private func requestPermissionPressed() {
        TelemetryManager.shared.recordSync(
            event: "onboarding_request_permission_clicked", level: "debug")
        onRequestPermission()
    }

    @objc private func openSettingsPressed() {
        TelemetryManager.shared.recordSync(
            event: "onboarding_open_settings_clicked", level: "debug")
        onOpenSettings()
    }

    @objc private func checkAgainPressed() {
        TelemetryManager.shared.recordSync(event: "onboarding_check_again_clicked", level: "debug")
        onCheckAgain()
    }

    @objc private func relaunchPressed() {
        TelemetryManager.shared.recordSync(event: "onboarding_relaunch_clicked", level: "debug")
        onRelaunch()
    }

    @objc private func quitPressed() {
        TelemetryManager.shared.recordSync(event: "onboarding_quit_clicked", level: "debug")
        onQuit()
    }

    @objc private func deletePressed() {
        TelemetryManager.shared.recordSync(event: "onboarding_delete_clicked", level: "debug")
        UninstallManager.confirmAndUninstall()
    }

    // MARK: - NSWindowDelegate: Prevent accidental closure
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSSound.beep()
        return false
    }
}
