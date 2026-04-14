import AppKit
import ApplicationServices
import Foundation

final class DismissOnBlurWindow: NSWindow {
    override func resignKey() {
        super.resignKey()
        TelemetryManager.shared.record(
            event: "settings_window_resign_key",
            level: "debug"
        )
    }

    override func cancelOperation(_ sender: Any?) {
        TelemetryManager.shared.record(
            event: "settings_window_cancel_close",
            level: "debug"
        )
        close()
    }
}

@MainActor
class ConfigPanelController: NSWindowController, NSWindowDelegate {
    // FIX: Track whether the singleton has been created. DeksApp checks this
    // before accessing .shared so it doesn't force-create the settings window
    // (and its full UI) during onboarding when only the permission window
    // should exist. Without this, accessing .shared triggers init() which
    // creates a hidden DismissOnBlurWindow that competes for z-order.
    private(set) static var isInitialized = false
    static let shared = ConfigPanelController()

    static func orderOutVisibleWindowIfInitialized() {
        guard isInitialized, let window = shared.window, window.isVisible else { return }
        window.orderOut(nil)
    }

    private let splitView = NSSplitView()
    private let leftList = NSTableView()
    private let rightList = NSTableView()

    private let leftPopup = NSPopUpButton()
    private let rightPopup = NSPopUpButton()
    private let addWorkspaceButton = NSButton(title: "+ Add Workspace", target: nil, action: nil)
    private let deleteWorkspaceButton = NSButton(
        title: "Delete Workspace", target: nil, action: nil)

    private let dragType = NSPasteboard.PasteboardType(rawValue: "com.deks.window.drag")

    enum ViewMode: Equatable {
        case workspace(UUID)
        case unassigned
    }

    private var leftMode: ViewMode?
    private var rightMode: ViewMode = .unassigned
    private var isUpdatingPopups = false
    private var reloadSequence = 0

    struct UnifiedWindow {
        let id: UUID
        let bundleID: String
        let title: String
        let appName: String
        var icon: NSImage?
    }

    private var leftWindows: [UnifiedWindow] = []
    private var rightWindows: [UnifiedWindow] = []
    private var stableOrderByMode: [String: [UUID]] = [:]

    private let leftNameField = NSTextField()
    private let leftColorSegment = NSSegmentedControl()
    private let leftIdleToggle = NSButton(
        checkboxWithTitle: "Pause in background", target: nil, action: nil)
    private let logoInHeaderToggle = NSButton(
        checkboxWithTitle: "Show Deks logo in menu bar", target: nil, action: nil)
    private let developerDiagnosticsToggle = NSButton(
        checkboxWithTitle: "Enable developer diagnostics logs", target: nil, action: nil)
    private let openLogsFolderButton = NSButton(title: "Open Logs Folder", target: nil, action: nil)
    private let quitSelectedAppButton = NSButton(title: "Quit Selected App", target: nil, action: nil)
    private let resetDataButton = NSButton(title: "Reset All Data", target: nil, action: nil)
    private let quitDeksButton = NSButton(title: "Quit Deks", target: nil, action: nil)
    private let settingsLogoView = NSImageView()
    private var renameDebounceWorkItem: DispatchWorkItem?
    private let colorChoices: [WorkspaceColor] = [
        .green, .purple, .coral, .blue, .amber, .pink, .red, .mint,
    ]

    init() {
        // Create an elegant, modern, vibrant macOS window
        let window = DismissOnBlurWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden  // We'll rely on the elegant layout structure
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        let visualEffect = NSVisualEffectView()
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.material = .sidebar
        window.contentView = visualEffect

        super.init(window: window)
        window.delegate = self

        setupUI(in: visualEffect)
        reload()

        // FIX: Mark singleton as initialized AFTER setup completes.
        ConfigPanelController.isInitialized = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func showWindow() {
        if !AXIsProcessTrusted() {
            NotificationCenter.default.post(name: .requestPermissionWalkthrough, object: nil)
            return
        }

        WorkspaceManager.shared.setManualOrganizationMode(true)

        logUI(
            "settings_show_window",
            metadata: [
                "leftMode": modeDescription(leftMode),
                "rightMode": modeDescription(rightMode),
            ]
        )

        super.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if leftMode == nil {
            if let active = WorkspaceManager.shared.activeWorkspaceId {
                leftMode = .workspace(active)
            } else {
                leftMode = .unassigned
            }
        }
        updatePopups()
        reloadData()
    }

    private func styleTable(_ table: NSTableView) {
        table.backgroundColor = .clear
        table.style = .inset
        table.rowHeight = 56
        table.intercellSpacing = NSSize(width: 0, height: 6)
        table.headerView = nil
        table.selectionHighlightStyle = .regular
        table.registerForDraggedTypes([dragType])
    }

    private func setupUI(in view: NSView) {
        let headerCard = NSVisualEffectView()
        headerCard.blendingMode = .behindWindow
        headerCard.state = .active
        headerCard.material = .menu
        headerCard.wantsLayer = true
        headerCard.layer?.cornerRadius = 12
        headerCard.layer?.masksToBounds = true
        headerCard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerCard)

        let titleLabel = NSTextField(labelWithString: "Deks Settings")
        titleLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(titleLabel)

        settingsLogoView.image = settingsHeaderLogoImage()
        settingsLogoView.imageScaling = .scaleProportionallyUpOrDown
        settingsLogoView.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(settingsLogoView)

        let subtitleLabel = NSTextField(
            labelWithString:
                "Double-click or drag windows across panels to organize your workspaces.")
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.isEditable = false
        subtitleLabel.isBordered = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(subtitleLabel)

        logoInHeaderToggle.target = self
        logoInHeaderToggle.action = #selector(logoHeaderToggled(_:))
        logoInHeaderToggle.font = .systemFont(ofSize: 12, weight: .medium)
        logoInHeaderToggle.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(logoInHeaderToggle)

        quitDeksButton.target = self
        quitDeksButton.action = #selector(quitDeksClicked)
        quitDeksButton.bezelStyle = .rounded
        quitDeksButton.controlSize = .small
        quitDeksButton.font = .systemFont(ofSize: 12, weight: .semibold)
        quitDeksButton.translatesAutoresizingMaskIntoConstraints = false
        headerCard.addSubview(quitDeksButton)

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)

        let leftContainer = NSView()
        leftContainer.wantsLayer = true
        leftContainer.layer?.cornerRadius = 12
        leftContainer.layer?.backgroundColor =
            NSColor.controlBackgroundColor.withAlphaComponent(0.55)
            .cgColor

        let rightContainer = NSView()
        rightContainer.wantsLayer = true
        rightContainer.layer?.cornerRadius = 12
        rightContainer.layer?.backgroundColor =
            NSColor.controlBackgroundColor.withAlphaComponent(0.55)
            .cgColor

        splitView.addSubview(leftContainer)
        splitView.addSubview(rightContainer)

        let leftSectionLabel = NSTextField(labelWithString: "Workspace Details")
        leftSectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        leftSectionLabel.textColor = .tertiaryLabelColor
        leftSectionLabel.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(leftSectionLabel)

        let rightSectionLabel = NSTextField(labelWithString: "Window Assignment")
        rightSectionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        rightSectionLabel.textColor = .tertiaryLabelColor
        rightSectionLabel.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(rightSectionLabel)

        leftPopup.target = self
        leftPopup.action = #selector(popupChanged(_:))
        leftPopup.controlSize = .large
        leftPopup.font = .systemFont(ofSize: 14, weight: .semibold)

        rightPopup.target = self
        rightPopup.action = #selector(popupChanged(_:))
        rightPopup.controlSize = .large
        rightPopup.font = .systemFont(ofSize: 14, weight: .semibold)

        addWorkspaceButton.target = self
        addWorkspaceButton.action = #selector(addWorkspaceClicked)
        addWorkspaceButton.controlSize = .large
        addWorkspaceButton.font = .systemFont(ofSize: 12, weight: .semibold)
        addWorkspaceButton.bezelStyle = .rounded

        deleteWorkspaceButton.target = self
        deleteWorkspaceButton.action = #selector(deleteWorkspaceClicked)
        deleteWorkspaceButton.controlSize = .large
        deleteWorkspaceButton.font = .systemFont(ofSize: 12, weight: .semibold)
        deleteWorkspaceButton.bezelStyle = .rounded

        leftNameField.placeholderString = "Workspace Name"
        leftNameField.font = .systemFont(ofSize: 13, weight: .bold)
        leftNameField.controlSize = .large
        leftNameField.delegate = self

        leftColorSegment.target = self
        leftColorSegment.action = #selector(colorChanged(_:))
        leftColorSegment.segmentStyle = .roundRect
        configureColorSwatches()

        leftIdleToggle.target = self
        leftIdleToggle.action = #selector(idleToggled(_:))

        developerDiagnosticsToggle.target = self
        developerDiagnosticsToggle.action = #selector(developerDiagnosticsToggled(_:))

        openLogsFolderButton.target = self
        openLogsFolderButton.action = #selector(openLogsFolderClicked)
        openLogsFolderButton.bezelStyle = .rounded
        openLogsFolderButton.controlSize = .small
        openLogsFolderButton.font = .systemFont(ofSize: 11, weight: .semibold)

        quitSelectedAppButton.target = self
        quitSelectedAppButton.action = #selector(quitSelectedAppClicked)
        quitSelectedAppButton.bezelStyle = .rounded
        quitSelectedAppButton.controlSize = .small
        quitSelectedAppButton.font = .systemFont(ofSize: 11, weight: .semibold)
        quitSelectedAppButton.contentTintColor = .systemRed

        let workspaceOptionsRow = NSStackView(views: [leftColorSegment, leftIdleToggle])
        workspaceOptionsRow.orientation = .horizontal
        workspaceOptionsRow.alignment = .centerY
        workspaceOptionsRow.spacing = 10

        let diagnosticsRow = NSStackView(views: [developerDiagnosticsToggle, openLogsFolderButton])
        diagnosticsRow.orientation = .horizontal
        diagnosticsRow.alignment = .centerY
        diagnosticsRow.spacing = 8
        openLogsFolderButton.setContentHuggingPriority(.required, for: .horizontal)
        openLogsFolderButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        resetDataButton.target = self
        resetDataButton.action = #selector(resetDataClicked)
        resetDataButton.bezelStyle = .rounded
        resetDataButton.controlSize = .small
        resetDataButton.font = .systemFont(ofSize: 11, weight: .semibold)
        resetDataButton.contentTintColor = .systemRed

        let actionsRow = NSStackView(views: [quitSelectedAppButton, resetDataButton])
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = 8
        quitSelectedAppButton.setContentHuggingPriority(.required, for: .horizontal)
        quitSelectedAppButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        resetDataButton.setContentHuggingPriority(.required, for: .horizontal)
        resetDataButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let settingsStack = NSStackView(views: [leftNameField, workspaceOptionsRow, diagnosticsRow, actionsRow])
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 10
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(settingsStack)

        let leftScroll = NSScrollView()
        leftScroll.drawsBackground = false
        leftScroll.hasVerticalScroller = true

        let leftCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("LeftCol"))
        leftCol.width = 400
        leftList.addTableColumn(leftCol)
        styleTable(leftList)
        leftList.dataSource = self
        leftList.delegate = self
        leftList.doubleAction = #selector(leftDoubleClicked)
        leftScroll.documentView = leftList

        let leftTopRow = NSStackView(views: [leftPopup, addWorkspaceButton, deleteWorkspaceButton])
        leftTopRow.orientation = .horizontal
        leftTopRow.alignment = .centerY
        leftTopRow.spacing = 8
        leftTopRow.translatesAutoresizingMaskIntoConstraints = false
        addWorkspaceButton.setContentHuggingPriority(.required, for: .horizontal)
        addWorkspaceButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        deleteWorkspaceButton.setContentHuggingPriority(.required, for: .horizontal)
        deleteWorkspaceButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        leftPopup.translatesAutoresizingMaskIntoConstraints = false
        leftScroll.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(leftTopRow)
        leftContainer.addSubview(leftScroll)

        let rightScroll = NSScrollView()
        rightScroll.drawsBackground = false
        rightScroll.hasVerticalScroller = true

        let rightCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RightCol"))
        rightCol.width = 400
        rightList.addTableColumn(rightCol)
        styleTable(rightList)
        rightList.dataSource = self
        rightList.delegate = self
        rightList.doubleAction = #selector(rightDoubleClicked)
        rightScroll.documentView = rightList

        rightPopup.translatesAutoresizingMaskIntoConstraints = false
        rightScroll.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.addSubview(rightPopup)
        rightContainer.addSubview(rightScroll)

        NSLayoutConstraint.activate([
            headerCard.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            headerCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            headerCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            titleLabel.topAnchor.constraint(equalTo: headerCard.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(
                equalTo: settingsLogoView.trailingAnchor, constant: 10),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(
                equalTo: settingsLogoView.trailingAnchor, constant: 10),
            subtitleLabel.bottomAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: -14),

            settingsLogoView.leadingAnchor.constraint(
                equalTo: headerCard.leadingAnchor, constant: 18),
            settingsLogoView.centerYAnchor.constraint(equalTo: headerCard.centerYAnchor),
            settingsLogoView.widthAnchor.constraint(equalToConstant: 28),
            settingsLogoView.heightAnchor.constraint(equalToConstant: 28),

            logoInHeaderToggle.centerYAnchor.constraint(equalTo: headerCard.centerYAnchor),
            logoInHeaderToggle.leadingAnchor.constraint(
                greaterThanOrEqualTo: subtitleLabel.trailingAnchor,
                constant: 16
            ),
            logoInHeaderToggle.trailingAnchor.constraint(
                equalTo: quitDeksButton.leadingAnchor, constant: -10),

            quitDeksButton.centerYAnchor.constraint(equalTo: headerCard.centerYAnchor),
            quitDeksButton.trailingAnchor.constraint(
                equalTo: headerCard.trailingAnchor, constant: -18),

            splitView.topAnchor.constraint(equalTo: headerCard.bottomAnchor, constant: 16),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),

            leftSectionLabel.topAnchor.constraint(equalTo: leftContainer.topAnchor, constant: 10),
            leftSectionLabel.leadingAnchor.constraint(
                equalTo: leftContainer.leadingAnchor, constant: 20),

            rightSectionLabel.topAnchor.constraint(equalTo: rightContainer.topAnchor, constant: 10),
            rightSectionLabel.leadingAnchor.constraint(
                equalTo: rightContainer.leadingAnchor, constant: 10),

            leftTopRow.topAnchor.constraint(equalTo: leftSectionLabel.bottomAnchor, constant: 6),
            leftTopRow.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 20),
            leftTopRow.trailingAnchor.constraint(
                equalTo: leftContainer.trailingAnchor, constant: -20),

            settingsStack.topAnchor.constraint(equalTo: leftTopRow.bottomAnchor, constant: 10),
            settingsStack.leadingAnchor.constraint(
                equalTo: leftContainer.leadingAnchor, constant: 20),
            settingsStack.trailingAnchor.constraint(
                equalTo: leftContainer.trailingAnchor, constant: -20),

            leftNameField.leadingAnchor.constraint(equalTo: settingsStack.leadingAnchor),
            leftNameField.trailingAnchor.constraint(equalTo: settingsStack.trailingAnchor),
            leftNameField.heightAnchor.constraint(equalToConstant: 30),

            workspaceOptionsRow.leadingAnchor.constraint(equalTo: settingsStack.leadingAnchor),
            workspaceOptionsRow.trailingAnchor.constraint(
                lessThanOrEqualTo: settingsStack.trailingAnchor),

            leftScroll.topAnchor.constraint(equalTo: settingsStack.bottomAnchor, constant: 10),
            leftScroll.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 20),
            leftScroll.trailingAnchor.constraint(
                equalTo: leftContainer.trailingAnchor, constant: -10),
            leftScroll.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor, constant: -12),

            rightPopup.topAnchor.constraint(equalTo: rightSectionLabel.bottomAnchor, constant: 6),
            rightPopup.leadingAnchor.constraint(
                equalTo: rightContainer.leadingAnchor, constant: 10),
            rightPopup.trailingAnchor.constraint(
                equalTo: rightContainer.trailingAnchor, constant: -20),

            rightScroll.topAnchor.constraint(equalTo: rightPopup.bottomAnchor, constant: 16),
            rightScroll.leadingAnchor.constraint(
                equalTo: rightContainer.leadingAnchor, constant: 10),
            rightScroll.trailingAnchor.constraint(
                equalTo: rightContainer.trailingAnchor, constant: -20),
            rightScroll.bottomAnchor.constraint(
                equalTo: rightContainer.bottomAnchor, constant: -12),
        ])
    }

    private func updatePopups() {
        isUpdatingPopups = true
        defer { isUpdatingPopups = false }

        normalizeViewModes()

        leftPopup.removeAllItems()
        rightPopup.removeAllItems()

        let wss = WorkspaceManager.shared.workspaces

        leftPopup.addItem(withTitle: "Available Unassigned Windows")
        leftPopup.lastItem?.representedObject = "unassigned"
        rightPopup.addItem(withTitle: "Available Unassigned Windows")
        rightPopup.lastItem?.representedObject = "unassigned"

        for ws in wss {
            leftPopup.addItem(withTitle: "Workspace: \(ws.name)")
            leftPopup.lastItem?.representedObject = ws.id
            rightPopup.addItem(withTitle: "Workspace: \(ws.name)")
            rightPopup.lastItem?.representedObject = ws.id
        }

        selectMode(leftMode, in: leftPopup)
        selectMode(rightMode, in: rightPopup)

        logUI(
            "settings_popups_updated",
            metadata: [
                "workspaceCount": String(wss.count),
                "leftMode": modeDescription(leftMode),
                "rightMode": modeDescription(rightMode),
            ]
        )
    }

    private func selectMode(_ mode: ViewMode?, in popup: NSPopUpButton) {
        guard let mode = mode else { return }
        switch mode {
        case .unassigned:
            popup.selectItem(at: 0)
        case .workspace(let id):
            if let idx = popup.itemArray.firstIndex(where: { ($0.representedObject as? UUID) == id }
            ) {
                popup.selectItem(at: idx)
            }
        }
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        if isUpdatingPopups { return }

        let selected = sender.selectedItem?.representedObject
        let mode: ViewMode = (selected as? UUID).map { .workspace($0) } ?? .unassigned
        let source = (sender === leftPopup) ? "left" : "right"
        let previous = (sender === leftPopup) ? leftMode : rightMode

        if sender === leftPopup {
            guard leftMode != mode else { return }
            leftMode = mode
        } else {
            guard rightMode != mode else { return }
            rightMode = mode
        }

        logUI(
            "settings_popup_changed",
            metadata: [
                "source": source,
                "from": modeDescription(previous),
                "to": modeDescription(mode),
            ]
        )
        reloadData()
    }

    private func normalizeViewModes() {
        let ids = Set(WorkspaceManager.shared.workspaces.map { $0.id })
        let oldLeft = leftMode
        let oldRight = rightMode

        if case .workspace(let id) = leftMode, !ids.contains(id) {
            leftMode =
                WorkspaceManager.shared.activeWorkspaceId.map { .workspace($0) } ?? .unassigned
        }

        if case .workspace(let id) = rightMode, !ids.contains(id) {
            rightMode = .unassigned
        }

        if oldLeft != leftMode || oldRight != rightMode {
            logUI(
                "settings_modes_normalized",
                metadata: [
                    "leftFrom": modeDescription(oldLeft),
                    "leftTo": modeDescription(leftMode),
                    "rightFrom": modeDescription(oldRight),
                    "rightTo": modeDescription(rightMode),
                ]
            )
        }
    }

    @objc private func addWorkspaceClicked() {
        let count = WorkspaceManager.shared.workspaces.count
        let name = "Workspace \(count + 1)"
        let color = colorChoices[count % colorChoices.count]
        let ws = WorkspaceManager.shared.createWorkspace(name: name, color: color)

        leftMode = .workspace(ws.id)
        updatePopups()
        reloadData()
    }

    @objc private func deleteWorkspaceClicked() {
        guard case .workspace(let id) = leftMode else { return }

        if WorkspaceManager.shared.workspaces.count <= 1 {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Cannot delete the last workspace"
            alert.informativeText = "Create another workspace first, then delete this one."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let targetName =
            WorkspaceManager.shared.workspaces.first(where: { $0.id == id })?.name
            ?? "this workspace"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete workspace?"
        alert.informativeText = "This will remove \"\(targetName)\" and its window assignments."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let didDelete = WorkspaceManager.shared.deleteWorkspace(id: id)
        if didDelete {
            leftMode =
                WorkspaceManager.shared.activeWorkspaceId.map { .workspace($0) } ?? .unassigned
            updatePopups()
            reloadData()
        }
    }

    func reload() {
        if let active = WorkspaceManager.shared.activeWorkspaceId, leftMode == nil {
            leftMode = .workspace(active)
        }
        updatePopups()
        reloadData()
    }

    private func fetchIcon(bundleID: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) {
            return app.icon
        }
        return nil
    }

    private func resolvedAppName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        })?.localizedName {
            return running
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let displayName = FileManager.default.displayName(atPath: url.path)
            if !displayName.isEmpty {
                return displayName.replacingOccurrences(of: ".app", with: "")
            }
        }

        return bundleID
    }

    private func settingsHeaderLogoImage() -> NSImage? {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            return icon
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let devCandidates = [
            cwd.appendingPathComponent("assets/AppIcon.icns"),
            cwd.appendingPathComponent("assets/deks-icon-512.png"),
            cwd.appendingPathComponent("../assets/AppIcon.icns"),
            cwd.appendingPathComponent("../assets/deks-icon-512.png"),
        ]
        for candidate in devCandidates {
            if let icon = NSImage(contentsOf: candidate) {
                return icon
            }
        }

        return nil
    }

    private func configureColorSwatches() {
        leftColorSegment.segmentCount = colorChoices.count
        leftColorSegment.trackingMode = .selectOne

        for (index, color) in colorChoices.enumerated() {
            leftColorSegment.setLabel("", forSegment: index)
            leftColorSegment.setImage(swatchImage(color: color.nsColor), forSegment: index)
            leftColorSegment.setToolTip(color.rawValue.capitalized, forSegment: index)
            leftColorSegment.setWidth(24, forSegment: index)
        }
    }

    private func swatchImage(color: NSColor) -> NSImage {
        let diameter: CGFloat = 12
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        image.unlockFocus()
        return image
    }

    private func colorIndex(_ c: WorkspaceColor) -> Int {
        colorChoices.firstIndex(of: c) ?? 0
    }

    private func colorFromIndex(_ idx: Int) -> WorkspaceColor {
        guard colorChoices.indices.contains(idx) else { return .green }
        return colorChoices[idx]
    }

    private func reloadData() {
        reloadSequence += 1
        let currentReload = reloadSequence

        let previousLeftSelection = selectedWindowID(in: leftList, source: leftWindows)
        let previousRightSelection = selectedWindowID(in: rightList, source: rightWindows)

        let leftVisibleRange = leftList.rows(in: leftList.visibleRect)
        let rightVisibleRange = rightList.rows(in: rightList.visibleRect)
        let previousLeftTopRow =
            leftVisibleRange.location == NSNotFound ? 0 : leftVisibleRange.location
        let previousRightTopRow =
            rightVisibleRange.location == NSNotFound ? 0 : rightVisibleRange.location

        let prefs = Persistence.loadPreferences()
        logoInHeaderToggle.state = prefs.showLogoInMenuBar ? .on : .off
        developerDiagnosticsToggle.state = prefs.developerDiagnosticsEnabled ? .on : .off
        quitSelectedAppButton.isEnabled = selectedBundleIDForQuit() != nil

        if case .workspace(let id) = leftMode,
            let ws = WorkspaceManager.shared.workspaces.first(where: { $0.id == id })
        {
            leftNameField.stringValue = ws.name
            leftColorSegment.selectedSegment = colorIndex(ws.color)
            leftIdleToggle.state = ws.idleOptimization ? .on : .off
            leftNameField.isHidden = false
            leftColorSegment.isHidden = false
            leftIdleToggle.isHidden = false
        } else {
            leftNameField.isHidden = true
            leftColorSegment.isHidden = true
            leftIdleToggle.isHidden = true
        }

        leftWindows = fetchWindows(for: leftMode)
        rightWindows = fetchWindows(for: rightMode)
        leftList.reloadData()
        rightList.reloadData()

        restoreSelection(previousLeftSelection, in: leftList, source: leftWindows)
        restoreSelection(previousRightSelection, in: rightList, source: rightWindows)

        if previousLeftTopRow < leftList.numberOfRows {
            leftList.scrollRowToVisible(previousLeftTopRow)
        }
        if previousRightTopRow < rightList.numberOfRows {
            rightList.scrollRowToVisible(previousRightTopRow)
        }

        logUI(
            "settings_reload_data",
            metadata: [
                "sequence": String(currentReload),
                "leftCount": String(leftWindows.count),
                "rightCount": String(rightWindows.count),
                "leftMode": modeDescription(leftMode),
                "rightMode": modeDescription(rightMode),
            ]
        )
    }

    private func commitWorkspaceRename(closeAfterCommit: Bool) {
        renameDebounceWorkItem?.cancel()
        renameDebounceWorkItem = nil

        guard case .workspace(let id) = leftMode else { return }
        WorkspaceManager.shared.renameWorkspace(id: id, to: leftNameField.stringValue)
        updatePopups()

        if closeAfterCommit {
            window?.performClose(nil)
        }
    }

    private func fetchWindows(for mode: ViewMode?) -> [UnifiedWindow] {
        guard let mode = mode else { return [] }
        switch mode {
        case .workspace(let id):
            guard let ws = WorkspaceManager.shared.workspaces.first(where: { $0.id == id }) else {
                return []
            }
            return ws.assignedWindows.map { ref in
                let appName = resolvedAppName(for: ref.bundleID)
                let icon = fetchIcon(bundleID: ref.bundleID)
                return UnifiedWindow(
                    id: ref.id, bundleID: ref.bundleID, title: ref.windowTitle, appName: appName,
                    icon: icon)
            }
        case .unassigned:
            WindowTracker.shared.synchronizeSession(workspaces: WorkspaceManager.shared.workspaces)
            let all = WindowTracker.shared.sessionWindows.values
            let filtered = all.filter { sessionWin in
                !WorkspaceManager.shared.workspaces.contains(where: { ws in
                    ws.assignedWindows.contains(where: { $0.id == sessionWin.id })
                })
            }
            let mapped = filtered.map {
                let icon = fetchIcon(bundleID: $0.bundleID)
                return UnifiedWindow(
                    id: $0.id, bundleID: $0.bundleID, title: $0.currentTitle, appName: $0.appName,
                    icon: icon)
            }
            return stableOrderedWindows(mapped, for: mode)
        }
    }

    private func stableOrderedWindows(_ windows: [UnifiedWindow], for mode: ViewMode)
        -> [UnifiedWindow]
    {
        let key = modeDescription(mode)
        let previousOrder = stableOrderByMode[key] ?? []

        let byID = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        var ordered: [UnifiedWindow] = []
        ordered.reserveCapacity(windows.count)

        for id in previousOrder {
            if let existing = byID[id] {
                ordered.append(existing)
            }
        }

        for win in windows where !previousOrder.contains(win.id) {
            ordered.append(win)
        }

        stableOrderByMode[key] = ordered.map(\.id)
        return ordered
    }

    @objc private func leftDoubleClicked() {
        if leftList.clickedRow >= 0 {
            moveItem(from: .left, index: leftList.clickedRow, to: .right)
        }
    }

    @objc private func rightDoubleClicked() {
        if rightList.clickedRow >= 0 {
            moveItem(from: .right, index: rightList.clickedRow, to: .left)
        }
    }

    enum Side { case left, right }

    private func moveItem(from src: Side, index: Int, to dst: Side) {
        let srcMode = src == .left ? leftMode : rightMode
        let dstMode = dst == .left ? leftMode : rightMode
        let win = (src == .left ? leftWindows : rightWindows)[index]

        if case .workspace(let id) = srcMode,
            let wsIndex = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == id })
        {
            WorkspaceManager.shared.workspaces[wsIndex].assignedWindows.removeAll {
                $0.id == win.id
            }
        }

        if case .workspace(let id) = dstMode,
            let wsIndex = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == id })
        {
            let ref: WindowRef
            if let sessionWin = WindowTracker.shared.sessionWindows[win.id],
                let windowNumber = sessionWin.windowNumber
            {
                ref = WindowRef(
                    id: win.id,
                    bundleID: win.bundleID,
                    windowTitle: win.title,
                    matchRule: .windowNumber(win.bundleID, windowNumber)
                )
            } else {
                ref = WindowRef(
                    id: win.id,
                    bundleID: win.bundleID,
                    windowTitle: win.title,
                    matchRule: .exactTitle(win.title)
                )
            }
            WorkspaceManager.shared.workspaces[wsIndex].assignedWindows.append(ref)
        }

        WorkspaceManager.shared.saveWorkspaces()
        WorkspaceManager.shared.persistActiveWorkspaceWindowOrder()

        // Live preview: hide/show the dragged window on screen so the user
        // immediately sees the effect of their edit. Only touches the single
        // window that was moved — windows in the active workspace that weren't
        // part of this edit are left alone.
        WorkspaceManager.shared.refreshVisibility(for: win.id)

        reloadData()
    }
}

@MainActor private var cellTitleLabelKey: UInt8 = 0

extension ConfigPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableView === leftList ? leftWindows.count : rightWindows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let win = (tableView === leftList) ? leftWindows[row] : rightWindows[row]
        let identifier = NSUserInterfaceItemIdentifier("ModernCell")

        var cellView =
            tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView

        if cellView == nil {
            let newCell = NSTableCellView()
            newCell.identifier = identifier

            // Background View for Hover/Selection effect internally
            let bgBox = NSBox()
            bgBox.boxType = .custom
            bgBox.borderWidth = 0
            bgBox.cornerRadius = 8
            bgBox.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.0)  // Transparent usually
            bgBox.translatesAutoresizingMaskIntoConstraints = false
            newCell.addSubview(bgBox)

            let imgView = NSImageView()
            imgView.translatesAutoresizingMaskIntoConstraints = false
            imgView.imageScaling = .scaleProportionallyUpOrDown

            let nameLabel = NSTextField(labelWithString: "")
            nameLabel.font = .systemFont(ofSize: 13, weight: .bold)
            nameLabel.textColor = .labelColor
            nameLabel.isEditable = false
            nameLabel.isBordered = false
            nameLabel.drawsBackground = false
            nameLabel.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = NSTextField(labelWithString: "")
            titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
            titleLabel.textColor = .secondaryLabelColor
            titleLabel.isEditable = false
            titleLabel.isBordered = false
            titleLabel.drawsBackground = false
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            newCell.addSubview(imgView)
            newCell.addSubview(nameLabel)
            newCell.addSubview(titleLabel)

            NSLayoutConstraint.activate([
                bgBox.topAnchor.constraint(equalTo: newCell.topAnchor),
                bgBox.bottomAnchor.constraint(equalTo: newCell.bottomAnchor),
                bgBox.leadingAnchor.constraint(equalTo: newCell.leadingAnchor),
                bgBox.trailingAnchor.constraint(equalTo: newCell.trailingAnchor),

                imgView.leadingAnchor.constraint(equalTo: newCell.leadingAnchor, constant: 12),
                imgView.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
                imgView.widthAnchor.constraint(equalToConstant: 30),
                imgView.heightAnchor.constraint(equalToConstant: 30),

                nameLabel.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 12),
                nameLabel.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -12),
                nameLabel.bottomAnchor.constraint(equalTo: newCell.centerYAnchor, constant: 1),

                titleLabel.leadingAnchor.constraint(equalTo: imgView.trailingAnchor, constant: 12),
                titleLabel.trailingAnchor.constraint(
                    equalTo: newCell.trailingAnchor, constant: -12),
                titleLabel.topAnchor.constraint(equalTo: newCell.centerYAnchor, constant: 3),
            ])

            newCell.imageView = imgView
            newCell.textField = nameLabel

            objc_setAssociatedObject(
                newCell, &cellTitleLabelKey, titleLabel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            cellView = newCell
        }

        cellView?.imageView?.image = win.icon
        cellView?.textField?.stringValue = win.appName

        if let titleLabel = objc_getAssociatedObject(cellView!, &cellTitleLabelKey) as? NSTextField
        {
            let displayTitle =
                win.title.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Main Application Window" : win.title
            titleLabel.stringValue = displayTitle
        }

        return cellView
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> NSPasteboardWriting?
    {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: dragType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let source = info.draggingSource as? NSTableView, source !== tableView else {
            return []
        }
        tableView.setDropRow(tableView.numberOfRows, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let source = info.draggingSource as? NSTableView, source !== tableView else {
            return false
        }
        guard let pbString = info.draggingPasteboard.string(forType: dragType),
            let index = Int(pbString)
        else { return false }
        let isSourceLeft = source === leftList
        moveItem(
            from: isSourceLeft ? .left : .right, index: index, to: isSourceLeft ? .right : .left)
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        quitSelectedAppButton.isEnabled = selectedBundleIDForQuit() != nil
    }
}

extension ConfigPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === leftNameField else { return }

        renameDebounceWorkItem?.cancel()
        let updatedName = field.stringValue
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, case .workspace(let id) = self.leftMode else { return }
            WorkspaceManager.shared.renameWorkspace(id: id, to: updatedName)
        }
        renameDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === leftNameField else { return }
        commitWorkspaceRename(closeAfterCommit: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        guard control === leftNameField else { return false }

        if commandSelector == #selector(NSResponder.insertNewline(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        {
            commitWorkspaceRename(closeAfterCommit: true)
            return true
        }

        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            window?.performClose(nil)
            return true
        }

        return false
    }

    @objc private func colorChanged(_ sender: NSSegmentedControl) {
        if case .workspace(let id) = leftMode,
            let idx = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == id })
        {
            WorkspaceManager.shared.workspaces[idx].color = colorFromIndex(sender.selectedSegment)
            WorkspaceManager.shared.saveWorkspaces()

            if id == WorkspaceManager.shared.activeWorkspaceId {
                MenuBarManager.shared.updateTitle()
            }
        }
    }

    @objc private func idleToggled(_ sender: NSButton) {
        if case .workspace(let id) = leftMode,
            let idx = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == id })
        {
            WorkspaceManager.shared.workspaces[idx].idleOptimization = (sender.state == .on)
            WorkspaceManager.shared.saveWorkspaces()
        }
    }

    @objc private func logoHeaderToggled(_ sender: NSButton) {
        var prefs = Persistence.loadPreferences()
        prefs.showLogoInMenuBar = (sender.state == .on)
        Persistence.savePreferences(prefs)
        MenuBarManager.shared.updateTitle()
    }

    @objc private func developerDiagnosticsToggled(_ sender: NSButton) {
        let enabled = (sender.state == .on)
        var prefs = Persistence.loadPreferences()
        prefs.developerDiagnosticsEnabled = enabled
        Persistence.savePreferences(prefs)

        // Used by WorkspaceManager for immediate runtime checks.
        UserDefaults.standard.set(enabled, forKey: "deks.devLogs")

        TelemetryManager.shared.record(
            event: enabled ? "developer_diagnostics_enabled" : "developer_diagnostics_disabled",
            level: "debug"
        )
    }

    @objc private func openLogsFolderClicked() {
        let logsDir = Persistence.appSupportDir.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([logsDir])
    }

    @objc private func quitSelectedAppClicked() {
        guard let bundleID = selectedBundleIDForQuit() else { return }
        _ = WorkspaceManager.shared.quitAppAndRemoveAssignments(bundleID: bundleID)
        WorkspaceManager.shared.persistActiveWorkspaceWindowOrder()
        updatePopups()
        reloadData()
    }

    @objc private func resetDataClicked() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all workspace data?"
        alert.informativeText =
            "This will delete all workspaces and their window assignments, then create a fresh Default workspace with your current windows."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        TelemetryManager.shared.record(event: "reset_all_data", level: "info")

        // Delete persisted data files
        try? FileManager.default.removeItem(at: Persistence.workspacesFileUrl())
        try? FileManager.default.removeItem(at: Persistence.appStateFileUrl())

        // Clear in-memory state and recreate a single Default workspace
        WorkspaceManager.shared.workspaces.removeAll()
        let defaultWs = WorkspaceManager.shared.createWorkspace(name: "Default", color: .blue)
        WorkspaceManager.shared.activeWorkspaceId = defaultWs.id

        // Re-discover current windows and assign them all to Default
        WindowTracker.shared.synchronizeSession(workspaces: WorkspaceManager.shared.workspaces)
        let seeded = WorkspaceManager.shared.seedActiveWorkspaceFromSessionIfNeeded()
        WorkspaceManager.shared.saveWorkspaces()

        TelemetryManager.shared.record(
            event: "reset_complete",
            metadata: ["windowsAssigned": String(seeded)]
        )

        // Refresh UI
        leftMode = .workspace(defaultWs.id)
        rightMode = .unassigned
        updatePopups()
        reloadData()
        MenuBarManager.shared.updateTitle()
    }

    @objc private func quitDeksClicked() {
        NSApp.terminate(nil)
    }

    // FIX: Defer the notification to the next run loop iteration so AppKit
    // finishes tearing down this window before handlePermissionWalkthroughRequest
    // tries to manipulate the z-order stack. Posting synchronously here caused
    // re-entrant orderOut on the already-closing window which corrupted ordering.
    func windowWillClose(_ notification: Notification) {
        WorkspaceManager.shared.persistActiveWorkspaceWindowOrder()
        let onboardingComplete = UserDefaults.standard.bool(forKey: "deks.onboardingComplete")
        if onboardingComplete {
            WorkspaceManager.shared.setManualOrganizationMode(false)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .requestPermissionWalkthrough, object: nil)
            }
        }
    }

    private func selectedWindowID(in tableView: NSTableView, source: [UnifiedWindow]) -> UUID? {
        let row = tableView.selectedRow
        guard row >= 0, row < source.count else { return nil }
        return source[row].id
    }

    private func selectedBundleIDForQuit() -> String? {
        let leftRow = leftList.selectedRow
        if leftRow >= 0, leftRow < leftWindows.count {
            return leftWindows[leftRow].bundleID
        }

        let rightRow = rightList.selectedRow
        if rightRow >= 0, rightRow < rightWindows.count {
            return rightWindows[rightRow].bundleID
        }

        if let focused = WindowTracker.shared.getFrontmostSessionWindow(), focused.appName != "Deks" {
            return focused.bundleID
        }

        return nil
    }

    private func restoreSelection(_ id: UUID?, in tableView: NSTableView, source: [UnifiedWindow]) {
        guard let id, let row = source.firstIndex(where: { $0.id == id }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func modeDescription(_ mode: ViewMode?) -> String {
        guard let mode else { return "none" }
        switch mode {
        case .unassigned:
            return "unassigned"
        case .workspace(let id):
            return "workspace:\(id.uuidString)"
        }
    }

    private func logUI(_ event: String, metadata: [String: String] = [:]) {
        TelemetryManager.shared.record(event: event, level: "debug", metadata: metadata)
    }
}
