import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

@MainActor
class MenuBarManager: NSObject {
    static let shared = MenuBarManager()
    private let maxMenuBarTitleCharacters = 18
    private let maxWorkspaceSubtitleApps = 3
    fileprivate let maxFolderButtonsShown = 4

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var escapeKeyMonitor: Any?
    private var globalEscapeKeyMonitor: Any?
    private var globalMouseDownMonitor: Any?

    private func menuBarLogoImage() -> NSImage? {
        // Prefer the bundled icns asset directly to avoid generic system fallback icons.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            let icon = NSImage(contentsOf: iconURL)
        {
            return icon
        }

        // Development fallback for `swift run` where resources are not in a full app bundle.
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

        // Secondary fallback: icon associated with this app bundle path.
        let bundlePath = Bundle.main.bundlePath
        if !bundlePath.isEmpty {
            return NSWorkspace.shared.icon(forFile: bundlePath)
        }
        return nil
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        // Wide view like the spec
        popover.contentViewController = MenuBarViewController()

        if escapeKeyMonitor == nil {
            escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self, self.popover.isShown else { return event }
                if event.keyCode == 53 {  // Escape key
                    self.closePopover()
                    return nil
                }
                return event
            }
        }

        if globalEscapeKeyMonitor == nil {
            globalEscapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
                [weak self] event in
                guard let self, self.popover.isShown else { return }
                if event.keyCode == 53 {  // Escape key
                    Task { @MainActor in
                        self.closePopover()
                    }
                }
            }
        }

        // Fallback: close popover when user clicks outside Deks and focus callbacks are delayed.
        if globalMouseDownMonitor == nil {
            globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                Task { @MainActor in
                    self.closePopover()
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTelemetryChanged),
            name: .windowOperationTelemetryChanged,
            object: nil
        )

        updateTitle()
    }

    func teardown() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
        if let monitor = globalEscapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeKeyMonitor = nil
        }
        if let monitor = globalMouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseDownMonitor = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    func updateTitle() {
        guard let button = statusItem.button else { return }

        let activeWs = WorkspaceManager.shared.workspaces.first {
            $0.id == WorkspaceManager.shared.activeWorkspaceId
        }
        let title = activeWs?.name ?? "Deks"
        let compactTitle = compactMenuBarTitle(title)
        let color = activeWs?.color.nsColor ?? .controlAccentColor
        let showLogo = Persistence.loadPreferences().showLogoInMenuBar

        if showLogo, let appIcon = menuBarLogoImage() {
            let icon = (appIcon.copy() as? NSImage) ?? appIcon
            icon.size = NSSize(width: 14, height: 14)
            button.image = icon
        } else {
            let dotSize = NSSize(width: 10, height: 10)
            let image = NSImage(size: dotSize)
            image.lockFocus()
            color.set()
            NSBezierPath(ovalIn: NSRect(origin: .zero, size: dotSize)).fill()
            image.unlockFocus()
            button.image = image
        }

        button.title = " " + compactTitle
        button.imagePosition = .imageLeft
        button.toolTip = "Workspace: \(title)\n\(WindowTracker.shared.telemetrySummary())"

        if popover.isShown {
            if let vc = popover.contentViewController as? MenuBarViewController {
                vc.reload()
            }
        }
    }

    private func compactMenuBarTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxMenuBarTitleCharacters else { return trimmed }

        let prefix = trimmed.prefix(max(1, maxMenuBarTitleCharacters - 1))
        return "\(prefix)…"
    }

    fileprivate func compactWorkspaceSubtitle(from groupedApps: [String: Int]) -> String {
        guard !groupedApps.isEmpty else { return "No windows assigned" }

        let sorted = groupedApps.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            return lhs.value > rhs.value
        }

        let visible = sorted.prefix(maxWorkspaceSubtitleApps).map { name, count in
            count > 1 ? "\(name) (\(count))" : name
        }

        let remainingGroups = sorted.count - visible.count
        if remainingGroups > 0 {
            return "\(visible.joined(separator: ", ")) +\(remainingGroups) folders"
        }
        return visible.joined(separator: ", ")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if let button = statusItem.button {
                NSApp.activate(ignoringOtherApps: true)
                if let vc = popover.contentViewController as? MenuBarViewController {
                    vc.reload()
                }
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                // Ensure controls render in active state and keyboard events reach the popover.
                DispatchQueue.main.async { [weak self] in
                    self?.popover.contentViewController?.view.window?.makeKey()
                }
            }
        }
    }
    func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    @objc private func handleAppDidResignActive() {
        closePopover()
    }

    @objc private func handleAppWillTerminate() {
        teardown()
    }

    @objc private func handleTelemetryChanged() {
        guard let button = statusItem.button else { return }
        let activeWs = WorkspaceManager.shared.workspaces.first {
            $0.id == WorkspaceManager.shared.activeWorkspaceId
        }
        let title = activeWs?.name ?? "Deks"
        button.toolTip = "Workspace: \(title)\n\(WindowTracker.shared.telemetrySummary())"
    }
}

// Custom View Controller to match the requested wide design
class MenuBarViewController: NSViewController {
    private struct AppFolderPayload {
        let workspaceId: UUID
        let appName: String
        let bundleIDs: Set<String>
    }

    private let stackView = NSStackView()
    private let searchField = NSSearchField()
    private var searchQuery = ""
    private var searchDebounceWorkItem: DispatchWorkItem?
    private var appNameCache: [String: String] = [:]
    private var lastRenderSignature = ""

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 50))  // Arbitrary start
        searchField.placeholderString = "Search workspaces/apps/windows"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 6

        container.addSubview(searchField)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stackView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            stackView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            stackView.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])

        self.view = container
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchDebounceWorkItem?.cancel()
        let query = sender.stringValue
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.searchQuery = query
            self.reload()
        }
        searchDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func appDisplayName(for bundleID: String) -> String {
        if let cached = appNameCache[bundleID] {
            return cached
        }

        let resolved: String
        if let mapped = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        })?.localizedName {
            resolved = mapped
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let displayName = FileManager.default.displayName(atPath: url.path)
            resolved = displayName.isEmpty
                ? bundleID
                : displayName.replacingOccurrences(of: ".app", with: "")
        } else {
            resolved = bundleID
        }

        appNameCache[bundleID] = resolved
        if appNameCache.count > 250 {
            appNameCache.removeAll(keepingCapacity: true)
        }
        return resolved
    }

    func reload() {
        let signature = buildRenderSignature()
        if signature == lastRenderSignature {
            return
        }
        lastRenderSignature = signature

        // Clear old
        stackView.views.forEach { $0.removeFromSuperview() }
        if searchField.stringValue != searchQuery {
            searchField.stringValue = searchQuery
        }
        let query = normalized(searchQuery)

        let focused = WindowTracker.shared.getFrontmostSessionWindow()
        let activeName =
            (focused?.appName == "Deks" || focused == nil) ? "No active window" : focused!.appName

        // Active window context
        let activeRow = NSStackView()
        activeRow.orientation = .horizontal
        activeRow.spacing = 6
        activeRow.alignment = .centerY
        let activeDot = NSTextField(labelWithString: "●")
        activeDot.font = .systemFont(ofSize: 8)
        activeDot.textColor = .systemGreen
        let activeLabel = NSTextField(labelWithString: activeName)
        activeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        activeLabel.textColor = .secondaryLabelColor
        activeLabel.lineBreakMode = .byTruncatingTail
        activeRow.addArrangedSubview(activeDot)
        activeRow.addArrangedSubview(activeLabel)
        stackView.addArrangedSubview(activeRow)

        // Only show telemetry details when developer diagnostics are enabled
        let showDiagnostics = Persistence.loadPreferences().developerDiagnosticsEnabled
        let telemetry = WindowTracker.shared.operationTelemetry

        if showDiagnostics {
            let telemetryText: String
            if telemetry.totalFailures == 0 {
                telemetryText = "Window Ops: healthy"
            } else {
                telemetryText =
                    "Window Ops: \(telemetry.totalFailures) failures (hide \(telemetry.hideFailures), show \(telemetry.showFailures), focus \(telemetry.focusFailures))"
            }
            let telemetryLabel = NSTextField(labelWithString: telemetryText)
            telemetryLabel.font = .systemFont(ofSize: 10, weight: .medium)
            telemetryLabel.textColor = telemetry.totalFailures == 0 ? .systemGreen : .systemRed
            stackView.addArrangedSubview(telemetryLabel)

            if let lastFailureAt = telemetry.lastFailureAt, let detail = telemetry.lastFailureDetail,
                telemetry.totalFailures > 0
            {
                let formatter = RelativeDateTimeFormatter()
                let relative = formatter.localizedString(for: lastFailureAt, relativeTo: Date())
                let detailLabel = NSTextField(
                    labelWithString: "Last failure \(relative): \(detail)")
                detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
                detailLabel.textColor = .tertiaryLabelColor
                detailLabel.maximumNumberOfLines = 2
                detailLabel.lineBreakMode = .byTruncatingTail
                stackView.addArrangedSubview(detailLabel)
            }
        } else if telemetry.totalFailures > 0 {
            // Show a subtle warning even for regular users when things are broken
            let warningLabel = NSTextField(
                labelWithString: "\(telemetry.totalFailures) window operation issue\(telemetry.totalFailures == 1 ? "" : "s")")
            warningLabel.font = .systemFont(ofSize: 10, weight: .medium)
            warningLabel.textColor = .systemOrange
            stackView.addArrangedSubview(warningLabel)
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

        if let focused = focused, focused.appName != "Deks" {
            let actionRow = NSStackView()
            actionRow.orientation = .horizontal
            actionRow.spacing = 12
            actionRow.alignment = .centerY

            let isPinned = WorkspaceManager.shared.isWindowPinned(focused.id)
            let pinTitle = isPinned ? "Unpin" : "Pin"
            let pinBtn = NSButton(
                title: pinTitle, target: self, action: #selector(togglePinFocusedWindow))
            pinBtn.isBordered = false
            pinBtn.contentTintColor = isPinned ? .systemOrange : .secondaryLabelColor
            pinBtn.font = .systemFont(ofSize: 11, weight: .semibold)
            actionRow.addArrangedSubview(pinBtn)

            let quitBtn = NSButton(
                title: "Quit App", target: self, action: #selector(quitFocusedApp))
            quitBtn.isBordered = false
            quitBtn.contentTintColor = .systemRed
            quitBtn.font = .systemFont(ofSize: 11, weight: .semibold)
            actionRow.addArrangedSubview(quitBtn)

            stackView.addArrangedSubview(actionRow)
        }

        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let workspaces = WorkspaceManager.shared.workspaces
        for (index, ws) in workspaces.enumerated() {
            let shortcutHint = index < 9 ? "  [^\(index + 1)]" : ""

            // Group windows into app-based "folders" to avoid a noisy subtitle.
            var groupedApps = [String: Int]()
            var groupBundleIDs = [String: Set<String>]()
            for win in ws.assignedWindows {
                let name = appDisplayName(for: win.bundleID)
                groupedApps[name, default: 0] += 1
                groupBundleIDs[name, default: []].insert(win.bundleID)
            }
            let pinnedCount = ws.assignedWindows.filter(\.isPinned).count
            let baseSubtitle = MenuBarManager.shared.compactWorkspaceSubtitle(from: groupedApps)
            let subtitle = pinnedCount > 0 ? "\(baseSubtitle)  •  📌\(pinnedCount)" : baseSubtitle

            if !query.isEmpty {
                let workspaceMatch = normalized(ws.name).contains(query)
                let appMatch = groupedApps.keys.contains(where: { normalized($0).contains(query) })
                let titleMatch = ws.assignedWindows.contains(where: {
                    normalized($0.windowTitle).contains(query)
                })
                if !workspaceMatch && !appMatch && !titleMatch {
                    continue
                }
            }

            // Build a proper two-line workspace row with fixed layout
            let rowContainer = NSView()
            rowContainer.translatesAutoresizingMaskIntoConstraints = false

            // Color dot
            let dotSize: CGFloat = 10
            let dotView = NSImageView()
            let dotImage = NSImage(size: NSSize(width: dotSize, height: dotSize))
            dotImage.lockFocus()
            ws.color.nsColor.set()
            NSBezierPath(ovalIn: NSRect(origin: .zero, size: NSSize(width: dotSize, height: dotSize))).fill()
            dotImage.unlockFocus()
            dotView.image = dotImage
            dotView.translatesAutoresizingMaskIntoConstraints = false
            rowContainer.addSubview(dotView)

            // Workspace name
            let nameText = ws.name + shortcutHint
            let nameLabel = NSTextField(labelWithString: nameText)
            nameLabel.font = .boldSystemFont(ofSize: 13)
            nameLabel.textColor = .labelColor
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            rowContainer.addSubview(nameLabel)

            // Subtitle (app summary)
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            rowContainer.addSubview(subtitleLabel)

            // Clickable overlay button
            let btn = NSButton(title: "", target: self, action: #selector(workspaceClicked(_:)))
            btn.isBordered = false
            btn.isTransparent = true
            btn.associatedId = ws.id
            btn.translatesAutoresizingMaskIntoConstraints = false
            rowContainer.addSubview(btn)

            NSLayoutConstraint.activate([
                rowContainer.heightAnchor.constraint(equalToConstant: 38),

                dotView.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor, constant: 2),
                dotView.centerYAnchor.constraint(equalTo: rowContainer.centerYAnchor),
                dotView.widthAnchor.constraint(equalToConstant: dotSize),
                dotView.heightAnchor.constraint(equalToConstant: dotSize),

                nameLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 8),
                nameLabel.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
                nameLabel.topAnchor.constraint(equalTo: rowContainer.topAnchor, constant: 2),

                subtitleLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 8),
                subtitleLabel.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
                subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),

                btn.topAnchor.constraint(equalTo: rowContainer.topAnchor),
                btn.bottomAnchor.constraint(equalTo: rowContainer.bottomAnchor),
                btn.leadingAnchor.constraint(equalTo: rowContainer.leadingAnchor),
                btn.trailingAnchor.constraint(equalTo: rowContainer.trailingAnchor),
            ])

            // Background highlight for active workspace
            if ws.id == WorkspaceManager.shared.activeWorkspaceId {
                let bgBox = NSBox()
                bgBox.boxType = .custom
                bgBox.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.2)
                bgBox.borderWidth = 0
                bgBox.cornerRadius = 6
                bgBox.translatesAutoresizingMaskIntoConstraints = false

                bgBox.addSubview(rowContainer)
                NSLayoutConstraint.activate([
                    rowContainer.topAnchor.constraint(equalTo: bgBox.topAnchor, constant: 4),
                    rowContainer.leadingAnchor.constraint(equalTo: bgBox.leadingAnchor, constant: 6),
                    rowContainer.trailingAnchor.constraint(equalTo: bgBox.trailingAnchor, constant: -6),
                ])

                if !groupedApps.isEmpty {
                    let folders = makeFolderButtons(
                        groupedApps: groupedApps,
                        groupedBundleIDs: groupBundleIDs,
                        workspaceId: ws.id
                    )
                    bgBox.addSubview(folders)
                    NSLayoutConstraint.activate([
                        folders.topAnchor.constraint(equalTo: rowContainer.bottomAnchor, constant: 4),
                        folders.leadingAnchor.constraint(equalTo: bgBox.leadingAnchor, constant: 10),
                        folders.trailingAnchor.constraint(equalTo: bgBox.trailingAnchor, constant: -10),
                        folders.bottomAnchor.constraint(equalTo: bgBox.bottomAnchor, constant: -6),
                    ])
                } else {
                    rowContainer.bottomAnchor.constraint(equalTo: bgBox.bottomAnchor, constant: -4).isActive = true
                }

                stackView.addArrangedSubview(bgBox)
                bgBox.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            } else {
                stackView.addArrangedSubview(rowContainer)
                rowContainer.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

                if !groupedApps.isEmpty {
                    let folders = makeFolderButtons(
                        groupedApps: groupedApps,
                        groupedBundleIDs: groupBundleIDs,
                        workspaceId: ws.id
                    )
                    stackView.addArrangedSubview(folders)
                    folders.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
                }
            }
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        stackView.setCustomSpacing(10, after: separator)

        let newWsBtn = NSButton(
            title: "+ New workspace", target: self, action: #selector(newWorkspaceClicked))
        newWsBtn.isBordered = false
        newWsBtn.contentTintColor = .labelColor
        newWsBtn.font = .systemFont(ofSize: 13, weight: .medium)
        stackView.addArrangedSubview(newWsBtn)
        stackView.setCustomSpacing(4, after: newWsBtn)

        let settingsBtn = NSButton(
            title: "Settings...", target: self, action: #selector(settingsClicked))
        settingsBtn.isBordered = false
        settingsBtn.contentTintColor = .labelColor
        settingsBtn.font = .systemFont(ofSize: 13, weight: .medium)
        stackView.addArrangedSubview(settingsBtn)
        stackView.setCustomSpacing(10, after: settingsBtn)

        let separatorBottom = NSBox()
        separatorBottom.boxType = .separator
        separatorBottom.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(separatorBottom)
        separatorBottom.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        stackView.setCustomSpacing(8, after: separatorBottom)

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

    private func buildRenderSignature() -> String {
        let activeID = WorkspaceManager.shared.activeWorkspaceId?.uuidString ?? "none"
        let workspaces = WorkspaceManager.shared.workspaces.map { ws in
            let ids = ws.assignedWindows.map(\.id.uuidString).joined(separator: ",")
            let pins = ws.assignedWindows.filter(\.isPinned).count
            return "\(ws.id.uuidString)|\(ws.name)|\(ws.color.rawValue)|\(pins)|\(ids)"
        }.joined(separator: "||")

        let focused = WindowTracker.shared.getFrontmostSessionWindow()?.id.uuidString ?? "none"
        let telemetry = WindowTracker.shared.operationTelemetry
        let telemetrySig =
            "\(telemetry.totalFailures)|\(telemetry.hideFailures)|\(telemetry.showFailures)|\(telemetry.focusFailures)"

        return [searchQuery, activeID, focused, telemetrySig, workspaces].joined(separator: "###")
    }

    private func makeFolderButtons(
        groupedApps: [String: Int],
        groupedBundleIDs: [String: Set<String>],
        workspaceId: UUID
    ) -> NSView {
        let sortedApps = groupedApps.sorted {
            if $0.value == $1.value {
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            return $0.value > $1.value
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        for (index, item) in sortedApps.enumerated() {
            if index >= MenuBarManager.shared.maxFolderButtonsShown { break }
            let title = item.value > 1 ? "\(item.key) (\(item.value))" : item.key
            let button = NSButton(title: title, target: self, action: #selector(folderClicked(_:)))
            button.isBordered = true
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 10, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            button.appFolderPayload = AppFolderPayload(
                workspaceId: workspaceId,
                appName: item.key,
                bundleIDs: groupedBundleIDs[item.key] ?? []
            )
            row.addArrangedSubview(button)
        }

        if sortedApps.count > MenuBarManager.shared.maxFolderButtonsShown {
            let extra = sortedApps.count - MenuBarManager.shared.maxFolderButtonsShown
            let more = NSTextField(labelWithString: "+\(extra)")
            more.font = .systemFont(ofSize: 10, weight: .semibold)
            more.textColor = .tertiaryLabelColor
            row.addArrangedSubview(more)
        }

        return row
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
                TelemetryManager.shared.record(
                    event: "login_service_toggle_failed",
                    level: "warning",
                    metadata: ["error": String(describing: error)]
                )
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
            let rule: WindowMatchRule
            if let windowNumber = focused.windowNumber {
                rule = .windowNumber(focused.bundleID, windowNumber)
            } else {
                rule = .exactTitle(focused.currentTitle)
            }

            let ref = WindowRef(
                id: focused.id, bundleID: focused.bundleID, windowTitle: focused.currentTitle,
                matchRule: rule)
            WorkspaceManager.shared.workspaces[idx].assignedWindows.append(ref)
            WorkspaceManager.shared.saveWorkspaces()
            WorkspaceManager.shared.persistActiveWorkspaceWindowOrder()

            if targetId != WorkspaceManager.shared.activeWorkspaceId {
                WindowTracker.shared.hideSessionWindow(focused)
            }
        }
        MenuBarManager.shared.closePopover()
    }

    @objc private func togglePinFocusedWindow() {
        guard let focused = WindowTracker.shared.getFrontmostSessionWindow() else { return }
        _ = WorkspaceManager.shared.togglePin(windowId: focused.id)
        reload()
    }

    @objc private func quitFocusedApp() {
        guard let focused = WindowTracker.shared.getFrontmostSessionWindow() else { return }
        guard focused.appName != "Deks" else { return }

        _ = WorkspaceManager.shared.quitAppAndRemoveAssignments(bundleID: focused.bundleID)
        reload()
    }

    @objc private func folderClicked(_ sender: NSButton) {
        guard let payload = sender.appFolderPayload as? AppFolderPayload else { return }

        WorkspaceManager.shared.switchTo(
            workspaceId: payload.workspaceId,
            source: "menu_folder_click"
        )
        WindowTracker.shared.synchronizeSession(workspaces: WorkspaceManager.shared.workspaces)

        guard
            let ws = WorkspaceManager.shared.workspaces.first(where: {
                $0.id == payload.workspaceId
            }),
            let ref = ws.assignedWindows.first(where: { payload.bundleIDs.contains($0.bundleID) }),
            let sessionWin = WindowTracker.shared.sessionWindows[ref.id]
        else {
            MenuBarManager.shared.closePopover()
            return
        }

        _ = WindowTracker.shared.showSessionWindow(sessionWin)
        _ = WindowTracker.shared.focusAndRaiseSessionWindow(sessionWin)
        MenuBarManager.shared.closePopover()
    }

    @objc private func workspaceClicked(_ sender: NSButton) {
        guard let id = sender.associatedId else { return }
        WorkspaceManager.shared.switchTo(
            workspaceId: id,
            source: "menu_workspace_click"
        )
        MenuBarManager.shared.closePopover()
    }

    @objc private func newWorkspaceClicked() {
        let count = WorkspaceManager.shared.workspaces.count
        let ws = WorkspaceManager.shared.createWorkspace(
            name: "Workspace \(count + 1)", color: .purple)
        WorkspaceManager.shared.switchTo(
            workspaceId: ws.id,
            source: "menu_new_workspace"
        )
        MenuBarManager.shared.closePopover()
    }

    @objc private func settingsClicked() {
        if !AXIsProcessTrusted() {
            NotificationCenter.default.post(name: .requestPermissionWalkthrough, object: nil)
            MenuBarManager.shared.closePopover()
            return
        }
        ConfigPanelController.shared.showWindow()
        MenuBarManager.shared.closePopover()
    }
}

// Helper association
@MainActor private var associatedIdKey: UInt8 = 0
@MainActor private var associatedFolderPayloadKey: UInt8 = 0
extension NSButton {
    var associatedId: UUID? {
        get { objc_getAssociatedObject(self, &associatedIdKey) as? UUID }
        set {
            objc_setAssociatedObject(
                self, &associatedIdKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    var appFolderPayload: Any? {
        get { objc_getAssociatedObject(self, &associatedFolderPayloadKey) }
        set {
            objc_setAssociatedObject(
                self, &associatedFolderPayloadKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
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
        case .red: return .systemRed
        case .mint: return .systemMint
        }
    }
}
