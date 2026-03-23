import AppKit
import Foundation
import ServiceManagement

@MainActor
class MenuBarManager: NSObject {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        // Wide view like the spec
        popover.contentViewController = MenuBarViewController()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTelemetryChanged),
            name: .windowOperationTelemetryChanged,
            object: nil
        )

        updateTitle()
    }

    func updateTitle() {
        guard let button = statusItem.button else { return }

        let activeWs = WorkspaceManager.shared.workspaces.first {
            $0.id == WorkspaceManager.shared.activeWorkspaceId
        }
        let title = activeWs?.name ?? "Deks"
        let color = activeWs?.color.nsColor ?? .controlAccentColor

        let dotSize = NSSize(width: 10, height: 10)
        let image = NSImage(size: dotSize)
        image.lockFocus()
        color.set()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: dotSize)).fill()
        image.unlockFocus()

        button.image = image
        button.title = " " + title
        button.imagePosition = .imageLeft
        button.toolTip = WindowTracker.shared.telemetrySummary()

        if popover.isShown {
            if let vc = popover.contentViewController as? MenuBarViewController {
                vc.reload()
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if let button = statusItem.button {
                if let vc = popover.contentViewController as? MenuBarViewController {
                    vc.reload()
                }
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func handleTelemetryChanged() {
        guard let button = statusItem.button else { return }
        button.toolTip = WindowTracker.shared.telemetrySummary()
        if popover.isShown, let vc = popover.contentViewController as? MenuBarViewController {
            vc.reload()
        }
    }
}

// Custom View Controller to match the requested wide design
class MenuBarViewController: NSViewController {
    private let stackView = NSStackView()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 50))  // Arbitrary start
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 14

        stackView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stackView.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])

        self.view = container
    }

    func reload() {
        // Clear old
        stackView.views.forEach { $0.removeFromSuperview() }

        let focused = WindowTracker.shared.getFrontmostSessionWindow()
        let activeName =
            (focused?.appName == "Deks" || focused == nil) ? "No active window" : focused!.appName

        let activeLabel = NSTextField(labelWithString: "Active: \(activeName)")
        activeLabel.font = .systemFont(ofSize: 11, weight: .bold)
        activeLabel.textColor = .secondaryLabelColor
        stackView.addArrangedSubview(activeLabel)

        let telemetry = WindowTracker.shared.operationTelemetry
        let telemetryText: String
        if telemetry.totalFailures == 0 {
            telemetryText = "Window Ops: healthy"
        } else {
            telemetryText =
                "Window Ops: \(telemetry.totalFailures) failures (hide \(telemetry.hideFailures), show \(telemetry.showFailures), focus \(telemetry.focusFailures))"
        }
        let telemetryLabel = NSTextField(labelWithString: telemetryText)
        telemetryLabel.font = .systemFont(ofSize: 11, weight: .medium)
        telemetryLabel.textColor = telemetry.totalFailures == 0 ? .systemGreen : .systemRed
        stackView.addArrangedSubview(telemetryLabel)

        if let lastFailureAt = telemetry.lastFailureAt, let detail = telemetry.lastFailureDetail,
            telemetry.totalFailures > 0
        {
            let formatter = RelativeDateTimeFormatter()
            let relative = formatter.localizedString(for: lastFailureAt, relativeTo: Date())
            let detailLabel = NSTextField(labelWithString: "Last failure \(relative): \(detail)")
            detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
            detailLabel.textColor = .tertiaryLabelColor
            detailLabel.maximumNumberOfLines = 2
            detailLabel.lineBreakMode = .byTruncatingTail
            stackView.addArrangedSubview(detailLabel)
        }

        let quickAssignPopup = NSPopUpButton()
        quickAssignPopup.target = self
        quickAssignPopup.action = #selector(quickAssignChanged(_:))

        quickAssignPopup.addItem(withTitle: "Move window to...")
        quickAssignPopup.lastItem?.representedObject = nil

        for ws in WorkspaceManager.shared.workspaces {
            quickAssignPopup.addItem(withTitle: ws.name)
            quickAssignPopup.lastItem?.representedObject = ws.id
        }

        quickAssignPopup.isEnabled = (focused != nil && focused!.appName != "Deks")

        if let focused = focused {
            // Set current assignment
            for ws in WorkspaceManager.shared.workspaces {
                if ws.assignedWindows.contains(where: { $0.id == focused.id }) {
                    quickAssignPopup.selectItem(withTitle: ws.name)
                    break
                }
            }
        }

        stackView.addArrangedSubview(quickAssignPopup)

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let workspaces = WorkspaceManager.shared.workspaces
        for (index, ws) in workspaces.enumerated() {
            let shortcutHint = index < 9 ? "  [^\(index + 1)]" : ""

            // Beautifully unique app names for subtitle string mapping
            var appNames = [String]()
            for win in ws.assignedWindows {
                let name: String
                if let mapped = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == win.bundleID
                })?.localizedName {
                    name = mapped
                } else {
                    name = (win.bundleID.components(separatedBy: ".").last ?? "").capitalized
                }
                if !appNames.contains(name) { appNames.append(name) }
            }
            let apps = appNames.joined(separator: ", ")
            let subtitle = apps.isEmpty ? "No windows assigned" : apps

            let btn = NSButton(title: "", target: self, action: #selector(workspaceClicked(_:)))
            btn.isBordered = false
            btn.contentTintColor = .labelColor
            btn.associatedId = ws.id

            let pstyle = NSMutableParagraphStyle()
            pstyle.lineBreakMode = .byTruncatingTail
            pstyle.lineSpacing = 2

            // Rich text formatting with integrated shortcut hint
            let primaryStr = NSMutableAttributedString(
                string: " \(ws.name)",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .paragraphStyle: pstyle])
            if !shortcutHint.isEmpty {
                let hintStr = NSAttributedString(
                    string: shortcutHint,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ])
                primaryStr.append(hintStr)
            }
            primaryStr.append(
                NSAttributedString(
                    string: "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]))

            let attrStr = NSMutableAttributedString()
            attrStr.append(primaryStr)
            attrStr.append(
                NSAttributedString(
                    string: "  " + subtitle,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))

            // Dot setup
            let dotAttachment = NSTextAttachment()
            let dotSize = NSSize(width: 10, height: 10)
            let image = NSImage(size: NSSize(width: 12, height: 12))  // slight padding
            image.lockFocus()
            ws.color.nsColor.set()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 1, width: 10, height: 10)).fill()
            image.unlockFocus()
            dotAttachment.image = image

            let finalStr = NSMutableAttributedString(attachment: dotAttachment)
            finalStr.append(attrStr)

            btn.attributedTitle = finalStr
            btn.alignment = .left  // Force left alignment explicitly
            btn.associatedId = ws.id

            // Background for active
            if ws.id == WorkspaceManager.shared.activeWorkspaceId {
                let bgBox = NSBox()
                bgBox.boxType = .custom
                bgBox.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.2)
                bgBox.borderWidth = 0
                bgBox.cornerRadius = 6

                bgBox.translatesAutoresizingMaskIntoConstraints = false
                btn.translatesAutoresizingMaskIntoConstraints = false
                bgBox.addSubview(btn)
                NSLayoutConstraint.activate([
                    btn.topAnchor.constraint(equalTo: bgBox.topAnchor, constant: 5),
                    btn.bottomAnchor.constraint(equalTo: bgBox.bottomAnchor, constant: -5),
                    btn.leadingAnchor.constraint(equalTo: bgBox.leadingAnchor, constant: 5),
                    btn.trailingAnchor.constraint(equalTo: bgBox.trailingAnchor, constant: -5),
                ])
                stackView.addArrangedSubview(bgBox)
                bgBox.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            } else {
                stackView.addArrangedSubview(btn)
                btn.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let newWsBtn = NSButton(
            title: "+ New workspace", target: self, action: #selector(newWorkspaceClicked))
        newWsBtn.isBordered = false
        newWsBtn.contentTintColor = .labelColor
        stackView.addArrangedSubview(newWsBtn)

        let settingsBtn = NSButton(
            title: "Settings...", target: self, action: #selector(settingsClicked))
        settingsBtn.isBordered = false
        settingsBtn.contentTintColor = .labelColor
        stackView.addArrangedSubview(settingsBtn)

        let separatorBottom = NSBox()
        separatorBottom.boxType = .separator
        separatorBottom.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separatorBottom)
        separatorBottom.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        if #available(macOS 13.0, *) {
            let status = (SMAppService.mainApp.status == .enabled)
            let loginBtn = NSButton(
                title: status ? "Launch at Login (Activated)" : "Enable Launch at Login",
                target: self, action: #selector(toggleLogin))
            loginBtn.isBordered = false
            loginBtn.contentTintColor = status ? .systemGreen : .secondaryLabelColor
            loginBtn.font = .systemFont(ofSize: 11, weight: .semibold)
            stackView.addArrangedSubview(loginBtn)
        }

        // Force layout pass cleanly
        self.view.layoutSubtreeIfNeeded()
    }

    @objc private func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
                MenuBarManager.shared.updateTitle()  // Refresh the UI state
            } catch {
                print("Failed to toggle login service: \(error)")
            }
        }
    }

    @objc private func quickAssignChanged(_ sender: NSPopUpButton) {
        guard let targetId = sender.selectedItem?.representedObject as? UUID else { return }
        guard let focused = WindowTracker.shared.getFrontmostSessionWindow() else { return }

        for i in 0..<WorkspaceManager.shared.workspaces.count {
            WorkspaceManager.shared.workspaces[i].assignedWindows.removeAll { $0.id == focused.id }
        }

        if let idx = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == targetId }) {
            let ref = WindowRef(
                id: focused.id, bundleID: focused.bundleID, windowTitle: focused.currentTitle,
                matchRule: .exactTitle(focused.currentTitle))
            WorkspaceManager.shared.workspaces[idx].assignedWindows.append(ref)
            WorkspaceManager.shared.saveWorkspaces()

            if targetId != WorkspaceManager.shared.activeWorkspaceId {
                WindowTracker.shared.hideSessionWindow(focused)
            }
        }
        MenuBarManager.shared.closePopover()
    }

    @objc private func workspaceClicked(_ sender: NSButton) {
        guard let id = sender.associatedId else { return }
        WorkspaceManager.shared.switchTo(workspaceId: id)
        MenuBarManager.shared.closePopover()
    }

    @objc private func newWorkspaceClicked() {
        let count = WorkspaceManager.shared.workspaces.count
        let ws = WorkspaceManager.shared.createWorkspace(
            name: "Workspace \(count + 1)", color: .purple)
        WorkspaceManager.shared.switchTo(workspaceId: ws.id)
        MenuBarManager.shared.closePopover()
    }

    @objc private func settingsClicked() {
        ConfigPanelController.shared.showWindow()
        MenuBarManager.shared.closePopover()
    }
}

// Helper association
@MainActor private var associatedIdKey: UInt8 = 0
extension NSButton {
    var associatedId: UUID? {
        get { objc_getAssociatedObject(self, &associatedIdKey) as? UUID }
        set {
            objc_setAssociatedObject(
                self, &associatedIdKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

extension WorkspaceColor {
    var nsColor: NSColor {
        switch self {
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .coral: return .systemOrange
        case .blue: return .systemBlue
        case .amber: return .systemYellow
        case .pink: return .systemPink
        }
    }
}
