import Foundation
import AppKit

@MainActor
class QuickSwitcher: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = QuickSwitcher()
    
    private let searchField = NSTextField()
    private let resultsTable = NSTableView()
    
    private var allWorkspaces: [Workspace] = []
    private var filteredWorkspaces: [Workspace] = []
    
    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.hudWindow, .nonactivatingPanel, .utilityWindow, .titled], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.center()
        
        super.init(window: panel)
        setupUI(in: panel.contentView!)
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI(in view: NSView) {
        searchField.frame = NSRect(x: 20, y: 340, width: 560, height: 40)
        searchField.font = .systemFont(ofSize: 24)
        searchField.delegate = self
        searchField.placeholderString = "Search Workspaces..."
        view.addSubview(searchField)
        
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 560, height: 300))
        resultsTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Col")))
        resultsTable.headerView = nil
        scroll.documentView = resultsTable
        resultsTable.dataSource = self
        resultsTable.delegate = self
        view.addSubview(scroll)
        
        // Register Option-Tab global hotkey logic is needed
        // For now, let's just make sure it opens when invoked.
    }
    
    func show() {
        allWorkspaces = WorkspaceManager.shared.workspaces
        filteredWorkspaces = allWorkspaces
        resultsTable.reloadData()
        searchField.stringValue = ""
        
        self.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func hide() {
        self.window?.orderOut(nil)
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
    
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let row = resultsTable.selectedRow
            if row >= 0 && row < filteredWorkspaces.count {
                let ws = filteredWorkspaces[row]
                WorkspaceManager.shared.switchTo(workspaceId: ws.id)
                hide()
            }
            return true
        } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hide()
            return true
        }
        return false
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int { return filteredWorkspaces.count }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let ws = filteredWorkspaces[row]
        let cell = NSTextField(labelWithString: ws.name)
        cell.font = .systemFont(ofSize: 18)
        return cell
    }
}
