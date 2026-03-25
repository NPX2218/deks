import AppKit
import Foundation

@MainActor
class QuickSwitcher: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    static let shared = QuickSwitcher()

    private let searchField = NSTextField()
    private let resultsTable = NSTableView()
    private let scrollView = NSScrollView()

    private var allWorkspaces: [Workspace] = []
    private var filteredWorkspaces: [Workspace] = []

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
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

        // Title
        let titleLabel = NSTextField(labelWithString: "Switch Workspace")
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(titleLabel)

        // Search field with custom styling
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.placeholderString = "Type to filter..."
        searchField.delegate = self
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.textColor = .white
        searchField.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(searchField)

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(separator)

        // Table view
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WorkspaceCol"))
        column.width = 480
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

        // Hint bar
        let hintLabel = NSTextField(labelWithString: "↑↓ Navigate  ⏎ Switch  ⎋ Close")
        hintLabel.font = .systemFont(ofSize: 10, weight: .medium)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.35)
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: visualEffect.topAnchor, constant: 14),
            titleLabel.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),

            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -20),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),

            hintLabel.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor, constant: -10),
            hintLabel.centerXAnchor.constraint(equalTo: visualEffect.centerXAnchor),
        ])
    }

    func show() {
        allWorkspaces = WorkspaceManager.shared.workspaces
        filteredWorkspaces = allWorkspaces
        resultsTable.reloadData()
        searchField.stringValue = ""

        // Pre-select the active workspace
        if let activeId = WorkspaceManager.shared.activeWorkspaceId,
            let idx = filteredWorkspaces.firstIndex(where: { $0.id == activeId })
        {
            resultsTable.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            resultsTable.scrollRowToVisible(idx)
        } else if !filteredWorkspaces.isEmpty {
            resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        // Center on screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowSize = self.window?.frame.size ?? NSSize(width: 520, height: 380)
            let x = screenFrame.midX - windowSize.width / 2
            let y = screenFrame.midY - windowSize.height / 2 + screenFrame.height * 0.1
            self.window?.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.window?.alphaValue = 0
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window?.makeFirstResponder(searchField)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            self.window?.animator().alphaValue = 1.0
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            self.window?.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                self?.window?.orderOut(nil)
            }
        })
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.lowercased()
        if query.isEmpty {
            filteredWorkspaces = allWorkspaces
        } else {
            filteredWorkspaces = allWorkspaces.filter { $0.name.lowercased().contains(query) }
        }
        resultsTable.reloadData()
        if !filteredWorkspaces.isEmpty {
            resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            switchToSelected()
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        } else if commandSelector == #selector(NSResponder.moveUp(_:)) {
            let row = max(0, resultsTable.selectedRow - 1)
            resultsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            resultsTable.scrollRowToVisible(row)
            return true
        } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
            let row = min(filteredWorkspaces.count - 1, resultsTable.selectedRow + 1)
            resultsTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            resultsTable.scrollRowToVisible(row)
            return true
        }
        return false
    }

    @objc private func tableDoubleClicked() {
        switchToSelected()
    }

    private func switchToSelected() {
        let row = resultsTable.selectedRow
        guard row >= 0, row < filteredWorkspaces.count else { return }
        let ws = filteredWorkspaces[row]
        WorkspaceManager.shared.switchTo(
            workspaceId: ws.id,
            source: "quick_switcher"
        )
        hide()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { return filteredWorkspaces.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let ws = filteredWorkspaces[row]
        let isActive = ws.id == WorkspaceManager.shared.activeWorkspaceId

        let cellView = NSView()

        // Colored dot
        let dotSize: CGFloat = 12
        let dot = NSImageView()
        let dotImage = NSImage(size: NSSize(width: dotSize, height: dotSize))
        dotImage.lockFocus()
        ws.color.nsColor.set()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: NSSize(width: dotSize, height: dotSize)))
            .fill()
        dotImage.unlockFocus()
        dot.image = dotImage
        dot.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(dot)

        // Workspace name
        let nameLabel = NSTextField(labelWithString: ws.name)
        nameLabel.font = .systemFont(ofSize: 15, weight: isActive ? .bold : .medium)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(nameLabel)

        // Window count subtitle
        let windowCount = ws.assignedWindows.count
        let subtitle =
            windowCount == 0
            ? "No windows" : windowCount == 1 ? "1 window" : "\(windowCount) windows"
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(subtitleLabel)

        // Hotkey hint on the right
        let hotkeyText: String
        if let idx = allWorkspaces.firstIndex(where: { $0.id == ws.id }), idx < 9 {
            hotkeyText = "^\(idx + 1)"
        } else {
            hotkeyText = ""
        }

        let hotkeyLabel = NSTextField(labelWithString: hotkeyText)
        hotkeyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        hotkeyLabel.textColor = NSColor.white.withAlphaComponent(0.3)
        hotkeyLabel.alignment = .right
        hotkeyLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(hotkeyLabel)

        // Active indicator
        if isActive {
            let activeTag = NSTextField(labelWithString: "active")
            activeTag.font = .systemFont(ofSize: 9, weight: .bold)
            activeTag.textColor = ws.color.nsColor
            activeTag.wantsLayer = true
            activeTag.layer?.cornerRadius = 3
            activeTag.layer?.backgroundColor = ws.color.nsColor.withAlphaComponent(0.15).cgColor
            activeTag.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(activeTag)

            NSLayoutConstraint.activate([
                activeTag.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
                activeTag.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: dotSize),
            dot.heightAnchor.constraint(equalToConstant: dotSize),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            nameLabel.bottomAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 2),

            subtitleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            subtitleLabel.topAnchor.constraint(equalTo: cellView.centerYAnchor, constant: 3),

            hotkeyLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -16),
            hotkeyLabel.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        ])

        return cellView
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return QuickSwitcherRowView()
    }
}

// Custom row view for rounded selection highlight
private class QuickSwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let selectionRect = bounds.insetBy(dx: 6, dy: 1)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.12).setFill()
        path.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .emphasized }
}
