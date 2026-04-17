import AppKit
import Foundation

/// Floating cheat-sheet that lists every command in the Deks command palette,
/// grouped by category with short descriptions. Triggered by selecting the
/// "Show Help" command inside the palette. Dismissed by Escape or by
/// clicking outside the window.
@MainActor
final class HelpPanel: NSWindowController {
    static let shared = HelpPanel()

    private var escapeKeyMonitor: Any?
    private var globalClickMonitor: Any?

    init() {
        let panel = HelpPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.center()

        super.init(window: panel)
        setupUI(in: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func setupUI(in panel: NSPanel) {
        let visualEffect = NSVisualEffectView()
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.material = .hudWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true
        visualEffect.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = visualEffect

        let title = NSTextField(labelWithString: "Deks · Window Commands")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = .white
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(title)

        let subtitle = NSTextField(
            labelWithString:
                "Press ⌃⌥W anywhere to open the palette.\n↑↓ Navigate commands   ⇥ / ⇧⇥ Switch target window   ⏎ Run   ⎋ Close"
        )
        subtitle.font = .systemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.6)
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 3
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(subtitle)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(separator)

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 2
        contentStack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 16, right: 16)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        // Keyboard shortcuts reference — always shown at the top of the help
        // so the user can see how to drive the palette without hunting.
        let shortcutsHeader = NSTextField(labelWithString: "KEYBOARD SHORTCUTS")
        shortcutsHeader.font = .systemFont(ofSize: 10, weight: .semibold)
        shortcutsHeader.textColor = NSColor.white.withAlphaComponent(0.45)
        contentStack.addArrangedSubview(shortcutsHeader)
        contentStack.setCustomSpacing(6, after: shortcutsHeader)

        for shortcut in keyboardShortcuts() {
            contentStack.addArrangedSubview(makeShortcutRow(shortcut))
        }
        if let lastShortcut = contentStack.arrangedSubviews.last {
            contentStack.setCustomSpacing(14, after: lastShortcut)
        }

        let groups = groupedCommands()
        for (index, group) in groups.enumerated() {
            let header = NSTextField(labelWithString: group.title)
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = NSColor.white.withAlphaComponent(0.45)
            contentStack.addArrangedSubview(header)
            contentStack.setCustomSpacing(6, after: header)

            for command in group.commands {
                let row = makeCommandRow(command)
                contentStack.addArrangedSubview(row)
            }

            if index < groups.count - 1, let last = contentStack.arrangedSubviews.last {
                contentStack.setCustomSpacing(14, after: last)
            }
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        scroll.documentView = documentView
        visualEffect.addSubview(scroll)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 18),
            title.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(
                equalTo: visualEffect.leadingAnchor, constant: 24),
            subtitle.trailingAnchor.constraint(
                equalTo: visualEffect.trailingAnchor, constant: -24),

            separator.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(
                equalTo: visualEffect.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(
                equalTo: visualEffect.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -12),

            documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    private func makeCommandRow(_ command: LayoutCommand) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: command.symbolName, accessibilityDescription: command.title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        icon.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)

        let nameLabel = NSTextField(labelWithString: command.title)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(nameLabel)

        let descriptionLabel = NSTextField(labelWithString: command.subtitle)
        descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        descriptionLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(descriptionLabel)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),

            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            nameLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nameLabel.widthAnchor.constraint(equalToConstant: 220),

            descriptionLabel.leadingAnchor.constraint(
                equalTo: nameLabel.trailingAnchor, constant: 10),
            descriptionLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            descriptionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -8),
        ])

        return container
    }

    private struct Shortcut {
        let keys: String
        let description: String
    }

    private func keyboardShortcuts() -> [Shortcut] {
        return [
            Shortcut(keys: "⌃⌥W", description: "Open the command palette"),
            Shortcut(keys: "↑ ↓", description: "Move up / down through the command list"),
            Shortcut(keys: "⇥", description: "Switch to next window in active workspace"),
            Shortcut(keys: "⇧⇥", description: "Switch to previous window in active workspace"),
            Shortcut(keys: "⏎", description: "Run the selected command on the target window"),
            Shortcut(keys: "⎋", description: "Close the palette without running anything"),
            Shortcut(keys: "Type", description: "Fuzzy-filter commands by name"),
        ]
    }

    private func makeShortcutRow(_ shortcut: Shortcut) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let keysBadge = NSView()
        keysBadge.wantsLayer = true
        keysBadge.layer?.cornerRadius = 4
        keysBadge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        keysBadge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(keysBadge)

        let keysLabel = NSTextField(labelWithString: shortcut.keys)
        keysLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        keysLabel.textColor = .white
        keysLabel.alignment = .center
        keysLabel.translatesAutoresizingMaskIntoConstraints = false
        keysBadge.addSubview(keysLabel)

        let descriptionLabel = NSTextField(labelWithString: shortcut.description)
        descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        descriptionLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(descriptionLabel)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),

            keysBadge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            keysBadge.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            keysBadge.widthAnchor.constraint(equalToConstant: 70),
            keysBadge.heightAnchor.constraint(equalToConstant: 22),

            keysLabel.centerXAnchor.constraint(equalTo: keysBadge.centerXAnchor),
            keysLabel.centerYAnchor.constraint(equalTo: keysBadge.centerYAnchor),
            keysLabel.leadingAnchor.constraint(
                equalTo: keysBadge.leadingAnchor, constant: 6),
            keysLabel.trailingAnchor.constraint(
                equalTo: keysBadge.trailingAnchor, constant: -6),

            descriptionLabel.leadingAnchor.constraint(
                equalTo: keysBadge.trailingAnchor, constant: 12),
            descriptionLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            descriptionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -8),
        ])

        return container
    }

    private struct Group {
        let title: String
        let commands: [LayoutCommand]
    }

    private func groupedCommands() -> [Group] {
        return [
            Group(
                title: "HALVES",
                commands: [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
            Group(
                title: "QUARTERS",
                commands: [
                    .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter,
                ]),
            Group(
                title: "THIRDS",
                commands: [
                    .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
                ]),
            Group(
                title: "FULL",
                commands: [.maximize, .almostMaximize, .center]),
            Group(title: "UNDO", commands: [.restorePrevious]),
            Group(title: "DISPLAY", commands: [.nextDisplay, .previousDisplay]),
            Group(
                title: "FOCUS",
                commands: [.focusNextWindowInWorkspace, .focusPreviousWindowInWorkspace]),
            Group(
                title: "WORKSPACE LAYOUT",
                commands: [
                    .tileWorkspaceAsGrid, .cascadeWorkspace, .columnsWorkspace, .rowsWorkspace,
                ]),
            Group(
                title: "REORDER IN WORKSPACE",
                commands: [
                    .moveWindowForwardInWorkspace, .moveWindowBackwardInWorkspace,
                    .bringWindowToFrontInWorkspace, .sendWindowToBackInWorkspace,
                ]),
        ]
    }

    // MARK: Show / hide

    func show() {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowSize = window?.frame.size ?? NSSize(width: 600, height: 620)
            let x = screenFrame.midX - windowSize.width / 2
            let y = screenFrame.midY - windowSize.height / 2 + screenFrame.height * 0.05
            window?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window?.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)

        if let window = window {
            let finalFrame = window.frame
            let shrink: CGFloat = 0.96
            let startFrame = NSRect(
                x: finalFrame.midX - finalFrame.width * shrink / 2,
                y: finalFrame.midY - finalFrame.height * shrink / 2,
                width: finalFrame.width * shrink,
                height: finalFrame.height * shrink
            )
            window.setFrame(startFrame, display: true)
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(finalFrame, display: true)
                window.animator().alphaValue = 1.0
            }
        } else {
            window?.makeKeyAndOrderFront(nil)
        }

        installDismissMonitors()
    }

    func hide() {
        removeDismissMonitors()
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.1
                self.window?.animator().alphaValue = 0.0
            },
            completionHandler: {
                Task { @MainActor [weak self] in
                    self?.window?.orderOut(nil)
                }
            })
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53 {  // Escape
                Task { @MainActor in self?.hide() }
                return nil
            }
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func removeDismissMonitors() {
        if let m = escapeKeyMonitor {
            NSEvent.removeMonitor(m)
            escapeKeyMonitor = nil
        }
        if let m = globalClickMonitor {
            NSEvent.removeMonitor(m)
            globalClickMonitor = nil
        }
    }
}

/// Borderless NSPanel that accepts key status so the escape key monitor works.
private final class HelpPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
