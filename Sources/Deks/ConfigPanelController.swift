import Foundation
import AppKit

@MainActor
class ConfigPanelController: NSWindowController {
    static let shared = ConfigPanelController()
    
    private let splitView = NSSplitView()
    private let leftList = NSTableView()
    private let rightList = NSTableView()
    
    private let leftPopup = NSPopUpButton()
    private let rightPopup = NSPopUpButton()
    
    private let dragType = NSPasteboard.PasteboardType(rawValue: "com.deks.window.drag")
    
    enum ViewMode: Equatable {
        case workspace(UUID)
        case unassigned
    }
    
    private var leftMode: ViewMode?
    private var rightMode: ViewMode = .unassigned
    
    struct UnifiedWindow {
        let id: UUID
        let bundleID: String
        let title: String
        let appName: String
        var icon: NSImage?
    }
    
    private var leftWindows: [UnifiedWindow] = []
    private var rightWindows: [UnifiedWindow] = []
    
    private let leftNameField = NSTextField()
    private let leftColorSegment = NSSegmentedControl(labels: ["🟢", "🟣", "🟠", "🔵", "🟡", "🩷"], trackingMode: .selectOne, target: nil, action: nil)
    private let leftIdleToggle = NSButton(checkboxWithTitle: "Pause in background", target: nil, action: nil)
    
    init() {
        // Create an elegant, modern, vibrant macOS window
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), 
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], 
                              backing: .buffered, defer: false)
        window.center()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden // We'll rely on the elegant layout structure
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        
        let visualEffect = NSVisualEffectView()
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.material = .sidebar
        window.contentView = visualEffect
        
        super.init(window: window)
        
        setupUI(in: visualEffect)
        reload()
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    func showWindow() {
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
        table.rowHeight = 52
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.headerView = nil
        table.selectionHighlightStyle = .regular
        table.registerForDraggedTypes([dragType])
    }
    
    private func setupUI(in view: NSView) {
        // App Header Title
        let titleLabel = NSTextField(labelWithString: "Deks Settings")
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        
        let subtitleLabel = NSTextField(labelWithString: "Double-click or drag windows across panels to organize your workspaces.")
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isEditable = false
        subtitleLabel.isBordered = false
        subtitleLabel.drawsBackground = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subtitleLabel)
        
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)
        
        let leftContainer = NSView()
        let rightContainer = NSView()
        splitView.addSubview(leftContainer)
        splitView.addSubview(rightContainer)
        
        // Popup Configurations
        leftPopup.target = self
        leftPopup.action = #selector(popupChanged(_:))
        leftPopup.controlSize = .large
        leftPopup.font = .systemFont(ofSize: 14, weight: .semibold)
        
        rightPopup.target = self
        rightPopup.action = #selector(popupChanged(_:))
        rightPopup.controlSize = .large
        rightPopup.font = .systemFont(ofSize: 14, weight: .semibold)
        
        leftNameField.placeholderString = "Workspace Name"
        leftNameField.font = .systemFont(ofSize: 13, weight: .bold)
        leftNameField.delegate = self
        
        leftColorSegment.target = self
        leftColorSegment.action = #selector(colorChanged(_:))
        leftColorSegment.segmentStyle = .roundRect
        
        leftIdleToggle.target = self
        leftIdleToggle.action = #selector(idleToggled(_:))
        
        let settingsStack = NSStackView(views: [leftNameField, leftColorSegment, leftIdleToggle])
        settingsStack.orientation = .horizontal
        settingsStack.spacing = 10
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(settingsStack)
        
        // Scroll Views
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
        
        leftPopup.translatesAutoresizingMaskIntoConstraints = false
        leftScroll.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(leftPopup)
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
        
        // Layout Constraints
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            
            splitView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 30),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            
            leftPopup.topAnchor.constraint(equalTo: leftContainer.topAnchor, constant: 0),
            leftPopup.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 20),
            leftPopup.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: -20),
            
            settingsStack.topAnchor.constraint(equalTo: leftPopup.bottomAnchor, constant: 10),
            settingsStack.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 20),
            settingsStack.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: -20),
            settingsStack.heightAnchor.constraint(equalToConstant: 24),
            
            leftScroll.topAnchor.constraint(equalTo: settingsStack.bottomAnchor, constant: 10),
            leftScroll.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 20),
            leftScroll.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: -10),
            leftScroll.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),
            
            rightPopup.topAnchor.constraint(equalTo: rightContainer.topAnchor, constant: 0),
            rightPopup.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor, constant: 10),
            rightPopup.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor, constant: -20),
            
            rightScroll.topAnchor.constraint(equalTo: rightPopup.bottomAnchor, constant: 16),
            rightScroll.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor, constant: 10),
            rightScroll.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor, constant: -20),
            rightScroll.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor)
        ])
    }
    
    private func updatePopups() {
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
    }
    
    private func selectMode(_ mode: ViewMode?, in popup: NSPopUpButton) {
        guard let mode = mode else { return }
        switch mode {
        case .unassigned:
            popup.selectItem(at: 0)
        case .workspace(let id):
            if let idx = popup.itemArray.firstIndex(where: { ($0.representedObject as? UUID) == id }) {
                popup.selectItem(at: idx)
            }
        }
    }
    
    @objc private func popupChanged(_ sender: NSPopUpButton) {
        let selected = sender.selectedItem?.representedObject
        let mode: ViewMode = (selected as? UUID).map { .workspace($0) } ?? .unassigned
        
        if sender === leftPopup { leftMode = mode } else { rightMode = mode }
        reloadData()
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
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return app.icon
        }
        return nil
    }
    
    private func colorIndex(_ c: WorkspaceColor) -> Int {
        switch c { case .green: return 0; case .purple: return 1; case .coral: return 2; case .blue: return 3; case .amber: return 4; case .pink: return 5 }
    }
    
    private func colorFromIndex(_ idx: Int) -> WorkspaceColor {
        switch idx { case 0: return .green; case 1: return .purple; case 2: return .coral; case 3: return .blue; case 4: return .amber; default: return .pink }
    }
    
    private func reloadData() {
        if case .workspace(let id) = leftMode, let ws = WorkspaceManager.shared.workspaces.first(where: { $0.id == id }) {
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
    }
    
    private func fetchWindows(for mode: ViewMode?) -> [UnifiedWindow] {
        guard let mode = mode else { return [] }
        switch mode {
        case .workspace(let id):
            guard let ws = WorkspaceManager.shared.workspaces.first(where: { $0.id == id }) else { return [] }
            return ws.assignedWindows.map { ref in
                let appName = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == ref.bundleID })?.localizedName ?? ref.bundleID.components(separatedBy: ".").last?.capitalized ?? ref.bundleID
                let icon = fetchIcon(bundleID: ref.bundleID)
                return UnifiedWindow(id: ref.id, bundleID: ref.bundleID, title: ref.windowTitle, appName: appName, icon: icon)
            }
        case .unassigned:
            WindowTracker.shared.synchronizeSession(workspaces: WorkspaceManager.shared.workspaces)
            let all = WindowTracker.shared.sessionWindows.values
            let filtered = all.filter { sessionWin in
                !WorkspaceManager.shared.workspaces.contains(where: { ws in ws.assignedWindows.contains(where: { $0.id == sessionWin.id }) })
            }
            return filtered.map { 
                let icon = fetchIcon(bundleID: $0.bundleID)
                return UnifiedWindow(id: $0.id, bundleID: $0.bundleID, title: $0.currentTitle, appName: $0.appName, icon: icon) 
            }
        }
    }
    
    @objc private func leftDoubleClicked() {
        if leftList.clickedRow >= 0 { moveItem(from: .left, index: leftList.clickedRow, to: .right) }
    }
    
    @objc private func rightDoubleClicked() {
        if rightList.clickedRow >= 0 { moveItem(from: .right, index: rightList.clickedRow, to: .left) }
    }
    
    enum Side { case left, right }
    
    private func moveItem(from src: Side, index: Int, to dst: Side) {
        let srcMode = src == .left ? leftMode : rightMode
        let dstMode = dst == .left ? leftMode : rightMode
        let win = (src == .left ? leftWindows : rightWindows)[index]
        
        if case .workspace(let id) = srcMode, let wsIndex = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == id }) {
            WorkspaceManager.shared.workspaces[wsIndex].assignedWindows.removeAll { $0.id == win.id }
        }
        
        if case .workspace(let id) = dstMode, let wsIndex = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == id }) {
            let ref = WindowRef(id: win.id, bundleID: win.bundleID, windowTitle: win.title, matchRule: .exactTitle(win.title))
            WorkspaceManager.shared.workspaces[wsIndex].assignedWindows.append(ref)
        }
        
        WorkspaceManager.shared.saveWorkspaces()
        reloadData()
    }
}

@MainActor fileprivate var cellTitleLabelKey: UInt8 = 0

extension ConfigPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return tableView === leftList ? leftWindows.count : rightWindows.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let win = (tableView === leftList) ? leftWindows[row] : rightWindows[row]
        let identifier = NSUserInterfaceItemIdentifier("ModernCell")
        
        var cellView = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
        
        if cellView == nil {
            let newCell = NSTableCellView()
            newCell.identifier = identifier
            
            // Background View for Hover/Selection effect internally
            let bgBox = NSBox()
            bgBox.boxType = .custom
            bgBox.borderWidth = 0
            bgBox.cornerRadius = 8
            bgBox.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.0) // Transparent usually
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
                titleLabel.trailingAnchor.constraint(equalTo: newCell.trailingAnchor, constant: -12),
                titleLabel.topAnchor.constraint(equalTo: newCell.centerYAnchor, constant: 3)
            ])
            
            newCell.imageView = imgView
            newCell.textField = nameLabel
            
            objc_setAssociatedObject(newCell, &cellTitleLabelKey, titleLabel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            cellView = newCell
        }
        
        cellView?.imageView?.image = win.icon
        cellView?.textField?.stringValue = win.appName
        
        if let titleLabel = objc_getAssociatedObject(cellView!, &cellTitleLabelKey) as? NSTextField {
            let displayTitle = win.title.trimmingCharacters(in: .whitespaces).isEmpty ? "Main Application Window" : win.title
            titleLabel.stringValue = displayTitle
        }
        
        return cellView
    }
    
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: dragType)
        return item
    }
    
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let source = info.draggingSource as? NSTableView, source !== tableView else { return [] }
        tableView.setDropRow(tableView.numberOfRows, dropOperation: .above)
        return .move
    }
    
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let source = info.draggingSource as? NSTableView, source !== tableView else { return false }
        guard let pbString = info.draggingPasteboard.string(forType: dragType), let index = Int(pbString) else { return false }
        let isSourceLeft = source === leftList
        moveItem(from: isSourceLeft ? .left : .right, index: index, to: isSourceLeft ? .right : .left)
        return true
    }
}

extension ConfigPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === leftNameField else { return }
        if case .workspace(let id) = leftMode, let idx = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == id }) {
            WorkspaceManager.shared.workspaces[idx].name = field.stringValue
            WorkspaceManager.shared.saveWorkspaces()
        }
    }
    
    @objc private func colorChanged(_ sender: NSSegmentedControl) {
        if case .workspace(let id) = leftMode, let idx = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == id }) {
            WorkspaceManager.shared.workspaces[idx].color = colorFromIndex(sender.selectedSegment)
            WorkspaceManager.shared.saveWorkspaces()
        }
    }
    
    @objc private func idleToggled(_ sender: NSButton) {
        if case .workspace(let id) = leftMode, let idx = WorkspaceManager.shared.workspaces.firstIndex(where: { $0.id == id }) {
            WorkspaceManager.shared.workspaces[idx].idleOptimization = (sender.state == .on)
            WorkspaceManager.shared.saveWorkspaces()
        }
    }
}
