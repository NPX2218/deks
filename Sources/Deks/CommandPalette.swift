import AppKit
import Foundation
import JavaScriptCore

/// A row in the command palette's results table.
/// - `.header` is a non-selectable section divider.
/// - `.suggestion` is a context-picked command (highlighted badge + reason).
/// - `.command` is a regular layout command.
/// - `.windowResult` is an open window that matched the query — ⏎ focuses it.
/// - `.calculatorResult` is a math expression the query was parsed as — ⏎
///   copies the value to the clipboard.
enum PaletteItem {
    case header(String)
    case suggestion(LayoutCommand, reason: String)
    case command(LayoutCommand)
    case windowResult(WindowTracker.SessionWindow)
    case calculatorResult(expression: String, formatted: String)

    var isSelectable: Bool {
        if case .header = self { return false }
        return true
    }
}

/// Raycast-style command palette for window layout commands. Triggered by
/// the global ⌃⌥W hotkey registered in WorkspaceManager. Operates on the
/// frontmost window (for per-window commands) or on the active workspace's
/// assigned windows (for workspace-wide commands).
@MainActor
final class CommandPalette: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    static let shared = CommandPalette()

    private let searchField = NSTextField()
    private let resultsTable = NSTableView()
    private let scrollView = NSScrollView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(
        labelWithString: "↑↓ Navigate   ⇥ Switch Window   ⏎ Run   ⎋ Close")

    private let allCommands: [LayoutCommand] = LayoutCommand.allCases
    private var filteredItems: [PaletteItem] = []
    private var appIconCache: [String: NSImage] = [:]

    /// The frontmost window captured at `show()` time, before Deks becomes
    /// the active app. Commands run against this stashed target so the layout
    /// manager doesn't end up trying to move Deks's own palette window.
    private var capturedTargetWindow: AXUIElement?

    /// Snapshot of session windows in the active workspace, in the workspace's
    /// persisted order. Populated at show() time so Tab / Shift-Tab can cycle
    /// the target without re-fetching on every keystroke.
    private var targetSessionWindows: [WindowTracker.SessionWindow] = []
    private var targetIndex: Int = 0

    init() {
        // Custom NSPanel subclass that overrides canBecomeKey — borderless
        // panels refuse key status by default, which would swallow arrow-key
        // and Return events before they reach the search field.
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    @objc private func handleWindowResignKey(_ notification: Notification) {
        guard window?.isVisible == true else { return }
        hide()
    }

    required init?(coder: NSCoder) { fatalError() }

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

        targetLabel.font = .systemFont(ofSize: 12, weight: .medium)
        targetLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        targetLabel.alignment = .center
        targetLabel.isEditable = false
        targetLabel.isBordered = false
        targetLabel.drawsBackground = false
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(targetLabel)

        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.placeholderString = "Search window commands…"
        searchField.delegate = self
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .white
        searchField.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(searchField)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CommandCol"))
        column.width = 520
        resultsTable.addTableColumn(column)
        resultsTable.headerView = nil
        resultsTable.backgroundColor = .clear
        resultsTable.rowHeight = 52
        resultsTable.intercellSpacing = NSSize(width: 0, height: 2)
        resultsTable.selectionHighlightStyle = .regular
        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.doubleAction = #selector(tableDoubleClicked)
        resultsTable.target = self

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = resultsTable
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(scrollView)

        hintLabel.font = .systemFont(ofSize: 10, weight: .medium)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.35)
        hintLabel.alignment = .center
        hintLabel.isEditable = false
        hintLabel.isBordered = false
        hintLabel.drawsBackground = false
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            targetLabel.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 16),
            targetLabel.leadingAnchor.constraint(
                equalTo: visualEffect.leadingAnchor, constant: 24),
            targetLabel.trailingAnchor.constraint(
                equalTo: visualEffect.trailingAnchor, constant: -24),

            searchField.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(
                equalTo: visualEffect.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(
                equalTo: visualEffect.trailingAnchor, constant: -20),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(
                equalTo: visualEffect.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(
                equalTo: visualEffect.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(
                equalTo: visualEffect.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(
                equalTo: visualEffect.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),

            hintLabel.bottomAnchor.constraint(
                equalTo: visualEffect.bottomAnchor, constant: -10),
            hintLabel.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
        ])
    }

    // MARK: Show / hide

    func toggle() {
        if window?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // Capture the frontmost window BEFORE Deks activates. This is the
        // user's actual target — once the palette is key, the AX "focused
        // window" would resolve to Deks itself.
        capturedTargetWindow = WindowLayoutManager.shared.captureFocusedWindow()
        NSLog("[Deks] CommandPalette.show: capturedTarget=\(capturedTargetWindow != nil)")

        rebuildTargetList()

        searchField.stringValue = ""
        rebuildItems(query: "")

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowSize = window?.frame.size ?? NSSize(width: 560, height: 420)
            let x = screenFrame.midX - windowSize.width / 2
            let y = screenFrame.midY - windowSize.height / 2 + screenFrame.height * 0.1
            window?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window?.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)

        // Pre-shrink the window to 96% centered so the entrance animation
        // scales up to full size — feels like Raycast's bounce-in instead of
        // a flat alpha fade.
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

        // Defer first-responder assignment until after the window has fully
        // become key, otherwise arrow keys and Return don't reach the search
        // field's field editor.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.searchField)
        }
    }

    func hide() {
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

    // MARK: Search / selection

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        rebuildItems(query: query)

        // Subtle alpha flicker so filter updates feel responsive — the rows
        // dim for one frame then fade back in over 100ms.
        scrollView.alphaValue = 0.55
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.scrollView.animator().alphaValue = 1.0
        }
    }

    /// Rebuild `filteredItems` and the table rows. Called from `show()`
    /// (empty query) and from every keystroke in the search field.
    ///
    /// Empty-query layout: SUGGESTED (context-picked) + ALL COMMANDS.
    /// Non-empty query: any matching sections of CALCULATOR / WINDOWS /
    /// COMMANDS, with headers only when the result is heterogeneous. A
    /// pure command search ("left half") still renders as a flat list.
    private func rebuildItems(query: String) {
        if query.isEmpty {
            var items: [PaletteItem] = []
            let suggestions = computeSuggestions()
            if !suggestions.isEmpty {
                items.append(.header("Suggested"))
                items.append(contentsOf: suggestions)
            }
            items.append(.header("All Commands"))
            items.append(contentsOf: allCommands.map { .command($0) })
            filteredItems = items
        } else {
            filteredItems = buildQueryResults(query: query)
        }

        resultsTable.reloadData()
        if let row = filteredItems.firstIndex(where: { $0.isSelectable }) {
            resultsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            resultsTable.scrollRowToVisible(row)
        }
    }

    private func buildQueryResults(query: String) -> [PaletteItem] {
        let calcRow: PaletteItem? = {
            guard let result = tryEvaluateAsMath(query) else { return nil }
            return .calculatorResult(
                expression: query, formatted: formatCalculatorResult(result))
        }()

        let windowRows: [PaletteItem] = WindowTracker.shared.sessionWindows.values
            .filter { $0.appName != "Deks" }
            .map { ($0, scoreWindow(win: $0, query: query)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { PaletteItem.windowResult($0.0) }

        let commandRows: [PaletteItem] = allCommands
            .map { ($0, score(command: $0, query: query)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { PaletteItem.command($0.0) }

        // Single-section flat list for the common case of just a command match.
        if calcRow == nil && windowRows.isEmpty {
            return commandRows
        }

        var items: [PaletteItem] = []
        if let calcRow {
            items.append(.header("Calculator"))
            items.append(calcRow)
        }
        if !windowRows.isEmpty {
            items.append(.header("Windows"))
            items.append(contentsOf: windowRows)
        }
        if !commandRows.isEmpty {
            items.append(.header("Commands"))
            items.append(contentsOf: commandRows)
        }
        return items
    }

    private func scoreWindow(win: WindowTracker.SessionWindow, query: String) -> Int {
        let haystack = "\(win.appName) \(win.currentTitle)".lowercased()
        if haystack == query { return 1000 }
        if haystack.hasPrefix(query) { return 500 }
        if haystack.contains(" " + query) { return 400 }
        if haystack.contains(query) { return 300 }

        var qi = query.startIndex
        for ch in haystack {
            if qi == query.endIndex { break }
            if ch == query[qi] { qi = query.index(after: qi) }
        }
        return qi == query.endIndex ? 80 : 0
    }

    /// Attempt to evaluate `query` as a math expression. Gated by a
    /// conservative regex (needs at least one digit-operator-digit pattern)
    /// so that typing command names doesn't trigger the calculator, and
    /// evaluated via JSContext so malformed input fails silently instead of
    /// crashing. Exponent (`^`) is intentionally omitted because JS treats
    /// it as XOR, not power.
    private func tryEvaluateAsMath(_ query: String) -> Double? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let allowed = CharacterSet(charactersIn: "0123456789+-*/.()% ")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        guard trimmed.range(
            of: #"\d+\s*[+\-*/%]\s*\d+"#, options: .regularExpression) != nil
        else {
            return nil
        }

        let ctx = JSContext()
        ctx?.exceptionHandler = { _, _ in }
        let jsResult = ctx?.evaluateScript(trimmed)
        guard let value = jsResult?.toNumber()?.doubleValue, value.isFinite else {
            return nil
        }
        return value
    }

    private func formatCalculatorResult(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 && abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        var s = String(format: "%.6f", value)
        while s.last == "0" { s.removeLast() }
        if s.last == "." { s.removeLast() }
        return s
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        if let cached = appIconCache[bundleID] { return cached }
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

    /// Context-aware layout picks based on how many windows are in the active
    /// workspace and the screen's aspect ratio. The goal is "one glance and
    /// the right thing is already highlighted." Heuristics are intentionally
    /// conservative — three suggestions max, ordered by likely relevance.
    private func computeSuggestions() -> [PaletteItem] {
        let count = targetSessionWindows.count
        let aspect = computeScreenAspect()
        let isWide = aspect >= 1.6
        let isTall = aspect < 1.3
        var suggestions: [PaletteItem] = []

        switch count {
        case 0, 1:
            suggestions.append(
                .suggestion(.almostMaximize, reason: "Fill almost the whole screen"))
            suggestions.append(
                .suggestion(.maximize, reason: "Fill the entire screen"))
            suggestions.append(
                .suggestion(.center, reason: "Center without resizing"))
        case 2:
            if isTall {
                suggestions.append(
                    .suggestion(.rowsWorkspace, reason: "Stack two windows top over bottom"))
                suggestions.append(
                    .suggestion(.columnsWorkspace, reason: "Split side by side"))
            } else {
                suggestions.append(
                    .suggestion(.columnsWorkspace, reason: "Split two windows side by side"))
                suggestions.append(
                    .suggestion(.rowsWorkspace, reason: "Stack top over bottom"))
            }
            suggestions.append(
                .suggestion(.cascadeWorkspace, reason: "Overlap with a slight offset"))
        case 3:
            if isWide {
                suggestions.append(
                    .suggestion(.columnsWorkspace, reason: "Three side-by-side columns"))
                suggestions.append(
                    .suggestion(.tileWorkspaceAsGrid, reason: "Tile three windows in a grid"))
            } else if isTall {
                suggestions.append(
                    .suggestion(.rowsWorkspace, reason: "Three stacked rows"))
                suggestions.append(
                    .suggestion(.tileWorkspaceAsGrid, reason: "Tile three windows in a grid"))
            } else {
                suggestions.append(
                    .suggestion(.tileWorkspaceAsGrid, reason: "Tile three windows in a 2×2 grid"))
                suggestions.append(
                    .suggestion(.columnsWorkspace, reason: "Three side-by-side columns"))
            }
        default:
            suggestions.append(
                .suggestion(
                    .tileWorkspaceAsGrid,
                    reason: "Tile all \(count) windows in a grid"))
            suggestions.append(
                .suggestion(
                    .cascadeWorkspace,
                    reason: "Cascade \(count) windows with offset"))
            if count == 4 && isWide {
                suggestions.append(
                    .suggestion(.columnsWorkspace, reason: "Four equal columns"))
            }
        }

        return suggestions
    }

    private func computeScreenAspect() -> CGFloat {
        let screen = window?.screen ?? NSScreen.main
        guard let frame = screen?.visibleFrame, frame.height > 0 else { return 1.6 }
        return frame.width / frame.height
    }

    private func nextSelectableRow(from row: Int, direction: Int) -> Int? {
        var r = row + direction
        while r >= 0 && r < filteredItems.count {
            if filteredItems[r].isSelectable { return r }
            r += direction
        }
        return nil
    }

    /// Simple fuzzy score: prefix match > word-start > contains > per-char
    /// subsequence. Higher is better; 0 means no match.
    private func score(command: LayoutCommand, query: String) -> Int {
        let haystack = command.searchText
        if haystack == query { return 1000 }
        if haystack.hasPrefix(query) { return 500 }
        if haystack.contains(" " + query) { return 400 }
        if haystack.contains(query) { return 300 }

        // Per-character subsequence match
        var qi = query.startIndex
        for ch in haystack {
            if qi == query.endIndex { break }
            if ch == query[qi] {
                qi = query.index(after: qi)
            }
        }
        return qi == query.endIndex ? 100 : 0
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            runSelected()
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
            if let target = nextSelectableRow(
                from: resultsTable.selectedRow, direction: -1)
            {
                resultsTable.selectRowIndexes(
                    IndexSet(integer: target), byExtendingSelection: false)
                resultsTable.scrollRowToVisible(target)
            }
            return true
        } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
            if let target = nextSelectableRow(
                from: resultsTable.selectedRow, direction: 1)
            {
                resultsTable.selectRowIndexes(
                    IndexSet(integer: target), byExtendingSelection: false)
                resultsTable.scrollRowToVisible(target)
            }
            return true
        } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
            cycleTarget(forward: true)
            return true
        } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            cycleTarget(forward: false)
            return true
        }
        return false
    }

    // MARK: Target cycling

    /// Populate `targetSessionWindows` from the active workspace's assigned
    /// windows (filtering to those Deks is currently tracking), and point
    /// `targetIndex` at whichever entry corresponds to the captured frontmost
    /// window — or fall back to the first entry.
    private func rebuildTargetList() {
        targetSessionWindows = []
        targetIndex = 0

        if let activeId = WorkspaceManager.shared.activeWorkspaceId,
            let workspace = WorkspaceManager.shared.workspaces.first(where: {
                $0.id == activeId
            })
        {
            targetSessionWindows = workspace.assignedWindows.compactMap {
                WindowTracker.shared.sessionWindows[$0.id]
            }
        }

        if let captured = capturedTargetWindow {
            let capturedHash = CFHash(captured)
            if let idx = targetSessionWindows.firstIndex(where: {
                CFHash($0.axElement) == capturedHash
            }) {
                targetIndex = idx
                updateTargetLabel(animated: false)
                return
            }
        }

        if let frontmost = WindowTracker.shared.getFrontmostSessionWindow(),
            let idx = targetSessionWindows.firstIndex(where: { $0.id == frontmost.id })
        {
            targetIndex = idx
        }
        updateTargetLabel(animated: false)
    }

    private func cycleTarget(forward: Bool) {
        guard !targetSessionWindows.isEmpty else { return }
        let count = targetSessionWindows.count
        let step = forward ? 1 : -1
        targetIndex = ((targetIndex + step) % count + count) % count
        updateTargetLabel()
    }

    /// Refresh the "Target: ..." header and re-point `capturedTargetWindow` at
    /// the currently-selected session window so `runSelected` will act on it.
    /// Flashes the label's alpha briefly so cycling with Tab/Shift-Tab feels
    /// responsive instead of silently swapping text.
    private func updateTargetLabel(animated: Bool = true) {
        guard !targetSessionWindows.isEmpty else {
            targetLabel.stringValue = "◌  No tracked windows in this workspace"
            targetLabel.textColor = NSColor.white.withAlphaComponent(0.35)
            targetLabel.alphaValue = 1.0
            return
        }
        let session = targetSessionWindows[targetIndex]
        let title = session.currentTitle
        let display = title.isEmpty ? session.appName : "\(session.appName)  ·  \(title)"
        let counter = "\(targetIndex + 1)/\(targetSessionWindows.count)"
        targetLabel.stringValue = "◉  \(display)   \(counter)"
        targetLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        capturedTargetWindow = session.axElement

        if animated {
            targetLabel.alphaValue = 0.25
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.targetLabel.animator().alphaValue = 1.0
            }
        } else {
            targetLabel.alphaValue = 1.0
        }
    }

    @objc private func tableDoubleClicked() {
        let clicked = resultsTable.clickedRow
        guard clicked >= 0, clicked < filteredItems.count,
            filteredItems[clicked].isSelectable
        else { return }
        resultsTable.selectRowIndexes(
            IndexSet(integer: clicked), byExtendingSelection: false)
        runSelected()
    }

    private func runSelected() {
        let row = resultsTable.selectedRow
        guard row >= 0, row < filteredItems.count else { return }
        let item = filteredItems[row]
        let target = capturedTargetWindow
        hide()

        switch item {
        case .header:
            return
        case .suggestion(let command, _), .command(let command):
            NSLog(
                "[Deks] CommandPalette.runSelected: \(command.rawValue) target=\(target != nil)")
            // The Help command isn't a layout op — route it to HelpPanel
            // directly instead of going through WindowLayoutManager.
            if command == .showHelp {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    HelpPanel.shared.show()
                }
                return
            }
            // Give the palette window a beat to start ordering out so the
            // target app can reclaim frontmost status.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                WindowLayoutManager.shared.apply(command, target: target)
            }
        case .windowResult(let win):
            NSLog("[Deks] CommandPalette.runSelected: focus window \(win.appName)")
            // If the target window lives in a different workspace, switch to
            // that workspace first — otherwise un-hiding just one window
            // leaves the UI in a mixed state with windows from two
            // workspaces visible at once.
            let owning = WorkspaceManager.shared.workspaces.first {
                $0.assignedWindows.contains(where: { $0.id == win.id })
            }
            if let owning, owning.id != WorkspaceManager.shared.activeWorkspaceId {
                WorkspaceManager.shared.switchTo(
                    workspaceId: owning.id,
                    force: true,
                    source: "palette_window_focus"
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                _ = WindowTracker.shared.showSessionWindow(win)
                _ = WindowTracker.shared.focusAndRaiseSessionWindow(win)
            }
        case .calculatorResult(_, let formatted):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formatted, forType: .string)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard row >= 0, row < filteredItems.count else { return nil }
        switch filteredItems[row] {
        case .header(let title):
            return makeHeaderCell(title: title)
        case .suggestion(let command, let reason):
            return makeCommandCell(
                command: command,
                subtitleOverride: reason,
                badgeText: "SUGGEST",
                badgeIsAccent: true)
        case .command(let command):
            return makeCommandCell(
                command: command,
                subtitleOverride: nil,
                badgeText: categoryBadge(for: command),
                badgeIsAccent: false)
        case .windowResult(let win):
            return makeWindowCell(win)
        case .calculatorResult(let expression, let formatted):
            return makeCalculatorCell(expression: expression, formatted: formatted)
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < filteredItems.count else { return 52 }
        if case .header = filteredItems[row] { return 26 }
        return 52
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < filteredItems.count else { return false }
        return filteredItems[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return CommandPaletteRowView()
    }

    private func makeHeaderCell(title: String) -> NSView {
        let cell = NSView()
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.45)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 22),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
        ])
        return cell
    }

    private func makeCommandCell(
        command: LayoutCommand,
        subtitleOverride: String?,
        badgeText: String,
        badgeIsAccent: Bool
    ) -> NSView {
        let cellView = NSView()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: command.symbolName, accessibilityDescription: command.title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.contentTintColor =
            badgeIsAccent
            ? NSColor.controlAccentColor
            : NSColor.white.withAlphaComponent(0.85)
        icon.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(icon)

        let nameLabel = NSTextField(labelWithString: command.title)
        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(nameLabel)

        let subtitleText = subtitleOverride ?? command.subtitle
        let subtitleLabel = NSTextField(labelWithString: subtitleText)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(
            badgeIsAccent ? 0.7 : 0.5)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(subtitleLabel)

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor =
            badgeIsAccent
            ? NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
            : NSColor.white.withAlphaComponent(0.1).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(badge)

        let badgeLabel = NSTextField(labelWithString: badgeText)
        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor =
            badgeIsAccent
            ? NSColor.controlAccentColor
            : NSColor.white.withAlphaComponent(0.7)
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            nameLabel.bottomAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 2),

            subtitleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            subtitleLabel.topAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 3),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badge.leadingAnchor, constant: -8),

            badge.trailingAnchor.constraint(
                equalTo: cellView.trailingAnchor, constant: -16),
            badge.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            badge.heightAnchor.constraint(equalToConstant: 20),

            badgeLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badgeLabel.leadingAnchor.constraint(
                equalTo: badge.leadingAnchor, constant: 8),
            badgeLabel.trailingAnchor.constraint(
                equalTo: badge.trailingAnchor, constant: -8),
        ])

        return cellView
    }

    private func makeWindowCell(_ win: WindowTracker.SessionWindow) -> NSView {
        let cellView = NSView()

        let icon = NSImageView()
        icon.image =
            appIcon(for: win.bundleID)
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(icon)

        let nameLabel = NSTextField(labelWithString: win.appName)
        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(nameLabel)

        let title = win.currentTitle.isEmpty ? "Untitled window" : win.currentTitle
        let subtitleLabel = NSTextField(labelWithString: title)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(subtitleLabel)

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(badge)

        let badgeLabel = NSTextField(labelWithString: "FOCUS")
        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            nameLabel.bottomAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 2),

            subtitleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            subtitleLabel.topAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 3),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badge.leadingAnchor, constant: -8),

            badge.trailingAnchor.constraint(
                equalTo: cellView.trailingAnchor, constant: -16),
            badge.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            badge.heightAnchor.constraint(equalToConstant: 20),

            badgeLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badgeLabel.leadingAnchor.constraint(
                equalTo: badge.leadingAnchor, constant: 8),
            badgeLabel.trailingAnchor.constraint(
                equalTo: badge.trailingAnchor, constant: -8),
        ])

        return cellView
    }

    private func makeCalculatorCell(expression: String, formatted: String) -> NSView {
        let cellView = NSView()

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "function", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.contentTintColor = NSColor.controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(icon)

        let nameLabel = NSTextField(labelWithString: "= \(formatted)")
        nameLabel.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(nameLabel)

        let subtitleLabel = NSTextField(
            labelWithString: "\(expression)   •   press ⏎ to copy")
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(subtitleLabel)

        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(badge)

        let badgeLabel = NSTextField(labelWithString: "COPY")
        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = NSColor.controlAccentColor
        badgeLabel.alignment = .center
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            nameLabel.bottomAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 2),

            subtitleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            subtitleLabel.topAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 3),
            subtitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badge.leadingAnchor, constant: -8),

            badge.trailingAnchor.constraint(
                equalTo: cellView.trailingAnchor, constant: -16),
            badge.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            badge.heightAnchor.constraint(equalToConstant: 20),

            badgeLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badgeLabel.leadingAnchor.constraint(
                equalTo: badge.leadingAnchor, constant: 8),
            badgeLabel.trailingAnchor.constraint(
                equalTo: badge.trailingAnchor, constant: -8),
        ])

        return cellView
    }

    private func categoryBadge(for command: LayoutCommand) -> String {
        switch command {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return "HALF"
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            return "QUARTER"
        case .leftThird, .centerThird, .rightThird: return "THIRD"
        case .leftTwoThirds, .rightTwoThirds: return "2 / 3"
        case .maximize, .almostMaximize, .center: return "FULL"
        case .restorePrevious: return "UNDO"
        case .nextDisplay, .previousDisplay: return "DISPLAY"
        case .tileWorkspaceAsGrid, .cascadeWorkspace, .columnsWorkspace, .rowsWorkspace:
            return "WORKSPACE"
        case .moveWindowForwardInWorkspace, .moveWindowBackwardInWorkspace,
            .bringWindowToFrontInWorkspace, .sendWindowToBackInWorkspace:
            return "REORDER"
        case .focusNextWindowInWorkspace, .focusPreviousWindowInWorkspace:
            return "FOCUS"
        case .showHelp:
            return "HELP"
        }
    }
}

/// Borderless NSPanel that accepts key status so arrow keys, Return, and
/// typing reach the search field. Default NSPanel `canBecomeKey` returns
/// false for borderless panels.
private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private class CommandPaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let selectionRect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.12).setFill()
        path.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .emphasized }
}
