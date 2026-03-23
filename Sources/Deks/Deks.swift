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
    private var permissionPollAttempts = 0
    private var permissionWindowController: PermissionOnboardingWindowController?

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
        let isTrusted = AXIsProcessTrusted()

        if isTrusted {
            completeSetupIfNeeded()
        } else {
            showPermissionWindowIfNeeded()
            updatePermissionUI()
            beginPermissionPolling()
        }
    }

    private func requestSystemPermissionPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        beginPermissionPolling()
        updatePermissionUI()
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
                    self.completeSetupIfNeeded()
                } else {
                    self.permissionPollAttempts += 1
                    self.updatePermissionUI()
                }
            }
        }
    }

    private func showPermissionWindowIfNeeded() {
        if permissionWindowController == nil {
            permissionWindowController = PermissionOnboardingWindowController(
                onRequestPermission: { [weak self] in self?.requestSystemPermissionPrompt() },
                onOpenSettings: { [weak self] in self?.openAccessibilitySettings() },
                onCheckAgain: { [weak self] in self?.requestPermissionsAndStart() },
                onRelaunch: { [weak self] in self?.relaunchApp() },
                onQuit: { NSApp.terminate(nil) }
            )
        }

        NSApp.activate(ignoringOtherApps: true)
        permissionWindowController?.showWindow(nil)
    }

    private func updatePermissionUI() {
        guard let controller = permissionWindowController else { return }
        let waitingLong = permissionPollAttempts >= delayedHintAttemptThreshold

        if waitingLong {
            controller.updateStatus(
                title: "Still waiting for Accessibility permission",
                detail:
                    "If you already enabled Deks, macOS may still be applying it. If stuck, toggle Deks off/on in Accessibility, press Check Again, then use Relaunch Deks."
            )
        } else {
            controller.updateStatus(
                title: "Step 1: Enable Accessibility for Deks",
                detail:
                    "Click Request Permission, enable Deks in Accessibility settings, then click Check Again."
            )
        }

        controller.updateContext(bundlePath: Bundle.main.bundlePath)
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
        permissionWindowController?.closeWindow()
        permissionWindowController = nil
        print("Accessibility permissions granted.")
        setupApp()
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
            print("Created Default workspace.")
        } else {
            print("Loaded workspaces: \(WorkspaceManager.shared.workspaces.count)")
        }

        IdleManager.shared.start()
        WorkspaceManager.shared.startAutoAssigner()

        // Move heavy window discovery to background to let UI appear immediately
        Task {
            // Discover first, then rebalance visibility without reassigning everything to active.
            WindowTracker.shared.synchronizeSession(workspaces: WorkspaceManager.shared.workspaces)
            WorkspaceManager.shared.startStartupRebalance()

            let windows = WindowTracker.shared.discoverWindows()
            print("Discovered \(windows.count) visible windows on screen.")
            for win in windows {
                print("  - \(win.appName): \(win.title)")
            }
        }
    }
}

@MainActor
final class PermissionOnboardingWindowController: NSWindowController {
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
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Finish Deks Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)

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
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitPressed))

        let buttonStack = NSStackView(views: [
            requestButton, openButton, checkButton, relaunchButton, quitButton,
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
        onRequestPermission()
    }

    @objc private func openSettingsPressed() {
        onOpenSettings()
    }

    @objc private func checkAgainPressed() {
        onCheckAgain()
    }

    @objc private func relaunchPressed() {
        onRelaunch()
    }

    @objc private func quitPressed() {
        onQuit()
    }
}
