import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

@MainActor
class MenuBarManager: NSObject {
    static let shared = MenuBarManager()
    private let maxMenuBarTitleCharacters = 18
    private let maxWorkspaceSubtitleApps = 3

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var escapeKeyMonitor: Any?
    private var globalEscapeKeyMonitor: Any?
    private var globalMouseDownMonitor: Any?
    /// The time the popover was last shown. Used to ignore the click that
    /// opened the popover — without this, the global mouse-down monitor fires
    /// for that same click and immediately closes the popover. 300ms is enough
    /// to cover event-queue processing after `popover.show`.
    private var popoverShownAt: Date?
    private let popoverOpenGraceInterval: TimeInterval = 0.3

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

        // .applicationDefined so NSPopover never auto-dismisses on its own. We
        // manage dismissal explicitly via the escape monitor, the global-mouse
        // outside-click monitor, and explicit action handlers. .transient caused
        // the popover to close whenever a child NSMenu (e.g. the "Move window
        // to…" popup) displayed, because AppKit treats the menu window as an
        // outside interaction.
        popover.behavior = .applicationDefined
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

        // Close popover when user clicks outside Deks. Required because the
        // popover uses .applicationDefined behavior (see setup). We gate on a
        // short "just-opened" grace period so the click that triggered the
        // status-item button action — which is still queued in the event loop
        // when this monitor fires — doesn't immediately close what it opened.
        if globalMouseDownMonitor == nil {
            globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                if let shownAt = self.popoverShownAt,
                    Date().timeIntervalSince(shownAt) < self.popoverOpenGraceInterval
                {
                    return
                }
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
            return "\(visible.joined(separator: ", ")) +\(remainingGroups) more"
        }
        return visible.joined(separator: ", ")
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            if let button = statusItem.button {
                // Capture the frontmost window BEFORE activating Deks. After
                // activate, the frontmost app is Deks and the real target is
                // lost.
                let lastFocused = WindowTracker.shared.getFrontmostSessionWindow()
                NSApp.activate(ignoringOtherApps: true)
                if let vc = popover.contentViewController as? MenuBarViewController {
                    vc.capturedLastFocused = lastFocused
                    vc.reload()
                }
                popoverShownAt = Date()
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                button.highlight(true)
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
        statusItem?.button?.highlight(false)
        popoverShownAt = nil
    }

    /// Close the popover synchronously (no animation), so there's no window
    /// still animating out when the caller opens another window right after.
    /// Used before transitioning to the Settings window — `performClose`'s
    /// animation would otherwise still be in flight when the settings
    /// window becomes key, which caused the "need to click Settings twice"
    /// bug.
    func closePopoverImmediately() {
        if popover.isShown {
            popover.close()
        }
        statusItem?.button?.highlight(false)
        popoverShownAt = nil
    }

    @objc private func handleAppDidResignActive() {
        // Intentionally a no-op. didResignActive also fires when a child NSMenu
        // (NSPopUpButton dropdown) takes focus — closing here would tear down the
        // popover mid-interaction. Outside-click dismissal is handled by the
        // global mouse-down monitor and escape-key monitor instead.
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

// MARK: - Visual style constants

enum PopoverStyle {
    // Layout
    static let popoverWidth: CGFloat = 340
    static let hPadding: CGFloat = 14
    static let vPadding: CGFloat = 14
    static let rowCornerRadius: CGFloat = 8
    static let footerIconIndent: CGFloat = 10

    // Opacity tiers — one source of truth so every surface feels consistent.
    static let subtleFill: CGFloat = 0.06      // chips, shortcut badges, quiet surfaces
    static let hoverFill: CGFloat = 0.09       // hover state for non-active rows / footer
    static let activeFill: CGFloat = 0.18      // selected workspace background
    static let activeHoverFill: CGFloat = 0.26 // selected workspace hover
}

// MARK: - Popover View Controller

class MenuBarViewController: NSViewController {
    private static let popoverWidth = PopoverStyle.popoverWidth
    private static let hPadding = PopoverStyle.hPadding
    private static let vPadding = PopoverStyle.vPadding

    private let stackView = NSStackView()
    private let searchField = NSSearchField()
    private var searchQuery = ""
    private var searchDebounceWorkItem: DispatchWorkItem?
    private var appNameCache: [String: String] = [:]
    private var appIconCache: [String: NSImage] = [:]
    private var lastRenderSignature = ""

    /// Window that was frontmost BEFORE the popover was opened. Cached at
    /// open-time because by the time the popover renders, `NSApp.activate`
    /// has already made Deks itself frontmost — `getFrontmostSessionWindow()`
    /// would otherwise resolve to Deks (and get filtered out).
    var capturedLastFocused: WindowTracker.SessionWindow?

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search workspaces, apps, windows"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.font = .systemFont(ofSize: 12)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(stackView)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.popoverWidth),

            searchField.topAnchor.constraint(
                equalTo: container.topAnchor, constant: Self.vPadding),
            searchField.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Self.hPadding),
            searchField.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.hPadding),

            stackView.topAnchor.constraint(
                equalTo: searchField.bottomAnchor, constant: 12),
            stackView.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Self.hPadding),
            stackView.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.hPadding),
            stackView.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -Self.vPadding),
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

    private func appIcon(for bundleID: String) -> NSImage? {
        if let cached = appIconCache[bundleID] {
            return cached
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            appIconCache[bundleID] = icon
            return icon
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        })?.icon {
            appIconCache[bundleID] = running
            return running
        }
        return nil
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

    // MARK: Row helpers

    private func addRow(_ view: NSView, spacingAfter: CGFloat? = nil) {
        stackView.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        if let spacing = spacingAfter {
            stackView.setCustomSpacing(spacing, after: view)
        }
    }

    private func addSectionHeader(_ title: String, spacingAfter: CGFloat = 4) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        addRow(label, spacingAfter: spacingAfter)
    }

    private func addSectionGap(_ amount: CGFloat) {
        guard let last = stackView.arrangedSubviews.last else { return }
        stackView.setCustomSpacing(amount, after: last)
    }

    // MARK: Render

    func reload() {
        let signature = buildRenderSignature()
        if signature == lastRenderSignature {
            return
        }
        lastRenderSignature = signature

        stackView.views.forEach { $0.removeFromSuperview() }
        if searchField.stringValue != searchQuery {
            searchField.stringValue = searchQuery
        }
        let query = normalized(searchQuery)

        renderCurrentWindowSection()
        addSectionGap(18)
        renderWorkspaceList(query: query)
        addSectionGap(16)
        renderFooter()

        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(
            width: Self.popoverWidth, height: view.fittingSize.height)
    }

    private func renderCurrentWindowSection() {
        let focused: WindowTracker.SessionWindow? = {
            guard let captured = capturedLastFocused, captured.appName != "Deks" else {
                return nil
            }
            return captured
        }()
        let hasFocus = focused != nil
        let activeName = hasFocus ? (focused?.appName ?? "") : "No active window"

        addSectionHeader("Last Focused")

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill

        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        if hasFocus, let bundleID = focused?.bundleID, let icon = appIcon(for: bundleID) {
            iconView.image = icon
        } else {
            iconView.image = NSImage(
                systemSymbolName: "app.dashed", accessibilityDescription: nil)
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 14, weight: .regular)
            iconView.contentTintColor = .tertiaryLabelColor
        }
        row.addArrangedSubview(iconView)

        let label = NSTextField(labelWithString: activeName)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = hasFocus ? .labelColor : .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)

        if hasFocus, let focused = focused {
            let isPinned = WorkspaceManager.shared.isWindowPinned(focused.id)
            let pinBtn = makeIconButton(
                symbol: isPinned ? "pin.slash.fill" : "pin.fill",
                tint: isPinned ? .systemOrange : .secondaryLabelColor,
                tooltip: isPinned ? "Unpin window" : "Pin window",
                action: #selector(togglePinFocusedWindow)
            )
            row.addArrangedSubview(pinBtn)

            let quitBtn = makeIconButton(
                symbol: "xmark.circle.fill",
                tint: .secondaryLabelColor,
                tooltip: "Quit app",
                action: #selector(quitFocusedApp)
            )
            row.addArrangedSubview(quitBtn)
        }

        addRow(row, spacingAfter: 8)

        // Telemetry warnings
        let showDiagnostics = Persistence.loadPreferences().developerDiagnosticsEnabled
        let telemetry = WindowTracker.shared.operationTelemetry

        if showDiagnostics {
            let telemetryText: String
            if telemetry.totalFailures == 0 {
                telemetryText = "Window ops: healthy"
            } else {
                telemetryText =
                    "Window ops: \(telemetry.totalFailures) failures (hide \(telemetry.hideFailures), show \(telemetry.showFailures), focus \(telemetry.focusFailures))"
            }
            let telemetryLabel = NSTextField(labelWithString: telemetryText)
            telemetryLabel.font = .systemFont(ofSize: 10, weight: .medium)
            telemetryLabel.textColor =
                telemetry.totalFailures == 0 ? .systemGreen : .systemRed
            telemetryLabel.lineBreakMode = .byTruncatingTail
            addRow(telemetryLabel, spacingAfter: 6)

            if let lastFailureAt = telemetry.lastFailureAt,
                let detail = telemetry.lastFailureDetail,
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
                addRow(detailLabel, spacingAfter: 8)
            }
        } else if telemetry.totalFailures > 0 {
            let warning = NSTextField(
                labelWithString:
                    "\(telemetry.totalFailures) window issue\(telemetry.totalFailures == 1 ? "" : "s")"
            )
            warning.font = .systemFont(ofSize: 11, weight: .medium)
            warning.textColor = .systemOrange
            addRow(warning, spacingAfter: 8)
        }

        // Move-to-workspace popup
        let popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(quickAssignChanged(_:))
        popup.font = .systemFont(ofSize: 12)
        popup.addItem(withTitle: "Move window to…")
        popup.lastItem?.representedObject = nil
        for ws in WorkspaceManager.shared.workspaces {
            popup.addItem(withTitle: ws.name)
            popup.lastItem?.representedObject = ws.id
        }
        popup.isEnabled = hasFocus

        if let focused = focused {
            for ws in WorkspaceManager.shared.workspaces {
                if ws.assignedWindows.contains(where: { $0.id == focused.id }) {
                    popup.selectItem(withTitle: ws.name)
                    break
                }
            }
        }
        addRow(popup)
    }

    private func renderWorkspaceList(query: String) {
        addSectionHeader("Workspaces")

        let workspaces = WorkspaceManager.shared.workspaces
        let activeId = WorkspaceManager.shared.activeWorkspaceId
        var rendered = 0

        for (index, ws) in workspaces.enumerated() {
            var groupedApps = [String: Int]()
            for win in ws.assignedWindows {
                let name = appDisplayName(for: win.bundleID)
                groupedApps[name, default: 0] += 1
            }
            let pinnedCount = ws.assignedWindows.filter(\.isPinned).count
            let subtitle = MenuBarManager.shared.compactWorkspaceSubtitle(from: groupedApps)

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

            let isActive = ws.id == activeId
            let shortcut: String? = index < 9 ? "⌃\(index + 1)" : nil

            let row = WorkspaceRowView(
                workspaceId: ws.id,
                name: ws.name,
                color: ws.color.nsColor,
                subtitle: subtitle,
                pinnedCount: pinnedCount,
                shortcut: shortcut,
                isActive: isActive,
                target: self,
                action: #selector(workspaceRowClicked(_:))
            )
            addRow(row, spacingAfter: 2)
            rendered += 1
        }

        if rendered == 0 {
            let empty = NSTextField(labelWithString: "No matches")
            empty.font = .systemFont(ofSize: 11, weight: .regular)
            empty.textColor = .tertiaryLabelColor
            addRow(empty, spacingAfter: 4)
        }
    }

    private func renderFooter() {
        let newBtn = makeFooterButton(
            title: "New workspace",
            symbol: "plus.circle.fill",
            tint: .controlAccentColor,
            action: #selector(newWorkspaceClicked)
        )
        addRow(newBtn, spacingAfter: 2)

        let settingsBtn = makeFooterButton(
            title: "Settings",
            symbol: "gearshape.fill",
            tint: .secondaryLabelColor,
            action: #selector(settingsClicked)
        )
        addRow(settingsBtn, spacingAfter: 2)

        if #available(macOS 13.0, *) {
            let enabled = (SMAppService.mainApp.status == .enabled)
            let loginBtn = makeFooterButton(
                title: enabled ? "Launch at login · On" : "Launch at login",
                symbol: enabled ? "checkmark.circle.fill" : "power.circle",
                tint: enabled ? .systemGreen : .secondaryLabelColor,
                action: #selector(toggleLogin)
            )
            addRow(loginBtn)
        }

        let brandLabel = NSTextField(
            labelWithString: "Deks · v\(ConfigPanelController.appVersionString())")
        brandLabel.font = .systemFont(ofSize: 10, weight: .medium)
        brandLabel.textColor = .tertiaryLabelColor
        brandLabel.alignment = .center
        let brandWrapper = NSView()
        brandWrapper.translatesAutoresizingMaskIntoConstraints = false
        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        brandWrapper.addSubview(brandLabel)
        NSLayoutConstraint.activate([
            brandLabel.centerXAnchor.constraint(equalTo: brandWrapper.centerXAnchor),
            brandLabel.topAnchor.constraint(equalTo: brandWrapper.topAnchor, constant: 10),
            brandLabel.bottomAnchor.constraint(equalTo: brandWrapper.bottomAnchor),
        ])
        addRow(brandWrapper)
    }

    private func buildRenderSignature() -> String {
        let activeID = WorkspaceManager.shared.activeWorkspaceId?.uuidString ?? "none"
        let workspaces = WorkspaceManager.shared.workspaces.map { ws in
            let ids = ws.assignedWindows.map(\.id.uuidString).joined(separator: ",")
            let pins = ws.assignedWindows.filter(\.isPinned).count
            return "\(ws.id.uuidString)|\(ws.name)|\(ws.color.rawValue)|\(pins)|\(ids)"
        }.joined(separator: "||")

        let focused = capturedLastFocused?.id.uuidString ?? "none"
        let telemetry = WindowTracker.shared.operationTelemetry
        let telemetrySig =
            "\(telemetry.totalFailures)|\(telemetry.hideFailures)|\(telemetry.showFailures)|\(telemetry.focusFailures)"

        return [searchQuery, activeID, focused, telemetrySig, workspaces].joined(separator: "###")
    }

    // MARK: Component factories

    private func makeIconButton(
        symbol: String, tint: NSColor, tooltip: String, action: Selector
    ) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let btn = NSButton()
        btn.isBordered = false
        btn.bezelStyle = .shadowlessSquare
        btn.imagePosition = .imageOnly
        btn.image = image
        btn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        btn.contentTintColor = tint
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.widthAnchor.constraint(equalToConstant: 22).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return btn
    }

    private func makeFooterButton(
        title: String, symbol: String, tint: NSColor, action: Selector
    ) -> NSButton {
        let btn = FooterButton(title: title, target: self, action: action)
        btn.isBordered = false
        btn.bezelStyle = .shadowlessSquare
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        btn.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        btn.imagePosition = .imageLeft
        btn.imageHugsTitle = true
        btn.contentTintColor = tint
        btn.font = .systemFont(ofSize: 12, weight: .medium)
        btn.alignment = .left
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return btn
    }

    // MARK: Actions

    @objc private func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
                MenuBarManager.shared.updateTitle()
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
        guard let focused = capturedLastFocused else { return }

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
        guard let focused = capturedLastFocused else { return }
        _ = WorkspaceManager.shared.togglePin(windowId: focused.id)
        lastRenderSignature = ""
        reload()
    }

    @objc private func quitFocusedApp() {
        guard let focused = capturedLastFocused else { return }
        guard focused.appName != "Deks" else { return }

        _ = WorkspaceManager.shared.quitAppAndRemoveAssignments(bundleID: focused.bundleID)
        lastRenderSignature = ""
        reload()
    }

    @objc private func workspaceRowClicked(_ sender: Any) {
        let id: UUID?
        if let row = sender as? WorkspaceRowView {
            id = row.workspaceId
        } else if let btn = sender as? NSButton {
            id = btn.associatedId
        } else {
            id = nil
        }
        guard let id else { return }
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
        // Close the popover SYNCHRONOUSLY (no fade-out animation) before
        // showing Settings. `performClose` animates asynchronously — even
        // with a deferred show, the popover's floating-level window was
        // still in flight when the settings window became key, which caused
        // the "need to click Settings twice" bug.
        MenuBarManager.shared.closePopoverImmediately()
        ConfigPanelController.shared.showWindow()
    }
}

// MARK: - Workspace row view

final class WorkspaceRowView: NSView {
    let workspaceId: UUID
    private let isActive: Bool
    private weak var target: AnyObject?
    private let action: Selector
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(
        workspaceId: UUID,
        name: String,
        color: NSColor,
        subtitle: String?,
        pinnedCount: Int,
        shortcut: String?,
        isActive: Bool,
        target: AnyObject?,
        action: Selector
    ) {
        self.workspaceId = workspaceId
        self.isActive = isActive
        self.target = target
        self.action = action
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        if #available(macOS 12.0, *) {
            layer?.cornerCurve = .continuous
        }
        updateBackground()

        let dotSize: CGFloat = 10
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = dotSize / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = isActive ? .controlAccentColor : .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)

        let hasSubtitle = !(subtitle?.isEmpty ?? true)
        let subtitleLabel = NSTextField(labelWithString: subtitle ?? "")
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.isHidden = !hasSubtitle
        addSubview(subtitleLabel)

        let trailingStack = NSStackView()
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 6
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.setContentHuggingPriority(.required, for: .horizontal)
        trailingStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(trailingStack)

        if pinnedCount > 0 {
            let pinWrap = NSStackView()
            pinWrap.orientation = .horizontal
            pinWrap.spacing = 2
            pinWrap.alignment = .centerY

            let icon = NSImageView()
            icon.image = NSImage(
                systemSymbolName: "pin.fill", accessibilityDescription: "Pinned windows")
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            icon.contentTintColor = .tertiaryLabelColor

            let countLabel = NSTextField(labelWithString: "\(pinnedCount)")
            countLabel.font = .systemFont(ofSize: 10, weight: .semibold)
            countLabel.textColor = .tertiaryLabelColor

            pinWrap.addArrangedSubview(icon)
            pinWrap.addArrangedSubview(countLabel)
            trailingStack.addArrangedSubview(pinWrap)
        }

        if let shortcut = shortcut {
            let badge = makeShortcutBadge(text: shortcut)
            trailingStack.addArrangedSubview(badge)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: dotSize),
            dot.heightAnchor.constraint(equalToConstant: dotSize),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -8),

            subtitleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -8),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if hasSubtitle {
            NSLayoutConstraint.activate([
                nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                subtitleLabel.topAnchor.constraint(
                    equalTo: nameLabel.bottomAnchor, constant: 2),
            ])
        } else {
            NSLayoutConstraint.activate([
                nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeShortcutBadge(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(PopoverStyle.subtleFill).cgColor
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: badge.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -2),
            badge.heightAnchor.constraint(equalToConstant: 18),
        ])
        return badge
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    private var mouseDownLocation: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        isPressed = true
        updateBackground()
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        updateBackground()
        defer { mouseDownLocation = nil }
        guard wasPressed, let start = mouseDownLocation else { return }
        let end = event.locationInWindow
        let dx = end.x - start.x
        let dy = end.y - start.y
        if dx * dx + dy * dy > 25 { return }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return }
        if let target, target.responds(to: action) {
            _ = target.perform(action, with: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateBackground() {
        let color: NSColor
        if isActive {
            let alpha =
                isPressed
                ? PopoverStyle.activeHoverFill + 0.06
                : (isHovered ? PopoverStyle.activeHoverFill : PopoverStyle.activeFill)
            color = NSColor.controlAccentColor.withAlphaComponent(alpha)
        } else if isPressed {
            color = NSColor.labelColor.withAlphaComponent(PopoverStyle.hoverFill + 0.05)
        } else if isHovered {
            color = NSColor.labelColor.withAlphaComponent(PopoverStyle.hoverFill)
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor
    }
}

// MARK: - Footer button (hover highlight + left-indented content)

final class FooterButtonCell: NSButtonCell {
    var leftInset: CGFloat = PopoverStyle.footerIconIndent
    var iconTitleGap: CGFloat = 8

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        var f = frame
        f.origin.x += leftInset
        super.drawImage(image, withFrame: f, in: controlView)
    }

    override func drawTitle(
        _ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView
    ) -> NSRect {
        var f = frame
        f.origin.x += leftInset + iconTitleGap
        return super.drawTitle(title, withFrame: f, in: controlView)
    }
}

final class FooterButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override class var cellClass: AnyClass? {
        get { FooterButtonCell.self }
        set {}
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    convenience init(title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor =
            NSColor.labelColor.withAlphaComponent(PopoverStyle.hoverFill).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Force the entire button frame to be clickable. Default NSButton
    /// hit-testing when `isBordered = false` is combined with our custom
    /// `FooterButtonCell` (which shifts the drawn icon and title) can leave
    /// dead zones — clicking between the icon and the title falls through
    /// the popover to the app underneath, stealing focus back to whatever
    /// was frontmost and looking like the click "failed."
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}

// MARK: - Helper association (workspace id pointer)

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
        case .red: return .systemRed
        case .mint: return .systemMint
        }
    }
}
