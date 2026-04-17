import AppKit
import ApplicationServices
import Foundation

/// Commands available in the Deks command palette for arranging windows.
///
/// Per-window commands operate on the frontmost AX-focused window. Workspace
/// commands iterate the active workspace's assigned windows and arrange them
/// on the main screen.
enum LayoutCommand: String, CaseIterable {
    // Halves
    case leftHalf, rightHalf, topHalf, bottomHalf
    // Quarters
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    // Thirds (ultrawide-friendly)
    case leftThird, centerThird, rightThird
    case leftTwoThirds, rightTwoThirds
    // Full / center
    case maximize, almostMaximize, center
    // Undo
    case restorePrevious
    // Displays
    case nextDisplay, previousDisplay
    // Workspace-wide
    case tileWorkspaceAsGrid, cascadeWorkspace, columnsWorkspace, rowsWorkspace
    // Reorder the focused window within its owning workspace's assigned list.
    // These mutate the persisted `assignedWindows` array so the order is
    // remembered across sessions.
    case moveWindowForwardInWorkspace, moveWindowBackwardInWorkspace
    case bringWindowToFrontInWorkspace, sendWindowToBackInWorkspace
    // Cycle focus through windows in the active workspace — so the user can
    // open the palette, jump to the next window, and immediately run another
    // tile command without reaching for the mouse.
    case focusNextWindowInWorkspace, focusPreviousWindowInWorkspace
    // Meta
    case showHelp

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeftQuarter: return "Top-Left Quarter"
        case .topRightQuarter: return "Top-Right Quarter"
        case .bottomLeftQuarter: return "Bottom-Left Quarter"
        case .bottomRightQuarter: return "Bottom-Right Quarter"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two-Thirds"
        case .rightTwoThirds: return "Right Two-Thirds"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .center: return "Center"
        case .restorePrevious: return "Restore Previous Size"
        case .nextDisplay: return "Move to Next Display"
        case .previousDisplay: return "Move to Previous Display"
        case .tileWorkspaceAsGrid: return "Tile Workspace as Grid"
        case .cascadeWorkspace: return "Cascade Workspace"
        case .columnsWorkspace: return "Workspace as Columns"
        case .rowsWorkspace: return "Workspace as Rows"
        case .moveWindowForwardInWorkspace: return "Move Window Forward"
        case .moveWindowBackwardInWorkspace: return "Move Window Backward"
        case .bringWindowToFrontInWorkspace: return "Bring Window to Front"
        case .sendWindowToBackInWorkspace: return "Send Window to Back"
        case .focusNextWindowInWorkspace: return "Focus Next Window"
        case .focusPreviousWindowInWorkspace: return "Focus Previous Window"
        case .showHelp: return "Show Help"
        }
    }

    var subtitle: String {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return "Half"
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            return "Quarter"
        case .leftThird, .centerThird, .rightThird: return "Third"
        case .leftTwoThirds, .rightTwoThirds: return "Two-Thirds"
        case .maximize, .almostMaximize: return "Fullscreen"
        case .center: return "Center on screen"
        case .restorePrevious: return "Undo last arrangement"
        case .nextDisplay, .previousDisplay: return "Display"
        case .tileWorkspaceAsGrid, .cascadeWorkspace, .columnsWorkspace, .rowsWorkspace:
            return "All windows in active workspace"
        case .moveWindowForwardInWorkspace, .moveWindowBackwardInWorkspace,
            .bringWindowToFrontInWorkspace, .sendWindowToBackInWorkspace:
            return "Reorder in workspace (persisted)"
        case .focusNextWindowInWorkspace, .focusPreviousWindowInWorkspace:
            return "Cycle focus in active workspace"
        case .showHelp:
            return "List every command with descriptions"
        }
    }

    var symbolName: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeftQuarter, .topRightQuarter, .bottomLeftQuarter, .bottomRightQuarter:
            return "square.grid.2x2.fill"
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds:
            return "rectangle.split.3x1"
        case .maximize: return "rectangle.inset.filled"
        case .almostMaximize: return "square.dashed"
        case .center: return "square.stack"
        case .restorePrevious: return "arrow.uturn.backward"
        case .nextDisplay, .previousDisplay: return "display"
        case .tileWorkspaceAsGrid: return "square.grid.3x3.fill"
        case .cascadeWorkspace: return "square.stack.3d.down.right.fill"
        case .columnsWorkspace: return "rectangle.split.3x1.fill"
        case .rowsWorkspace: return "rectangle.split.1x2.fill"
        case .moveWindowForwardInWorkspace: return "arrow.up"
        case .moveWindowBackwardInWorkspace: return "arrow.down"
        case .bringWindowToFrontInWorkspace: return "arrow.up.to.line"
        case .sendWindowToBackInWorkspace: return "arrow.down.to.line"
        case .focusNextWindowInWorkspace: return "arrow.right.circle.fill"
        case .focusPreviousWindowInWorkspace: return "arrow.left.circle.fill"
        case .showHelp: return "questionmark.circle.fill"
        }
    }

    /// Lowercased text used for fuzzy matching in the palette.
    var searchText: String {
        title.lowercased()
    }
}

@MainActor
final class WindowLayoutManager {
    static let shared = WindowLayoutManager()
    private init() {}

    /// Most-recent frame of windows before the latest layout command was
    /// applied. Keyed by `CFHash` of the AXUIElement — stable within a session.
    private var previousFrames: [CFHashCode: CGRect] = [:]

    // MARK: Public API

    /// Capture the frontmost non-Deks window's AX element. The command
    /// palette calls this **before** it becomes active so the caller can
    /// stash the target window — by the time the user picks a command, Deks
    /// is the frontmost app and `focusedWindowElement()` would otherwise
    /// return nil (it deliberately skips Deks's own windows).
    func captureFocusedWindow() -> AXUIElement? {
        return focusedWindowElement()
    }

    /// Apply the given layout command. No-op if the command has no valid
    /// target. If `target` is provided it's used directly; otherwise the
    /// manager looks up the current frontmost window.
    func apply(_ command: LayoutCommand, target: AXUIElement? = nil) {
        let element = target ?? focusedWindowElement()
        NSLog(
            "[Deks] WindowLayoutManager apply: \(command.rawValue), hasTarget=\(element != nil)")

        switch command {
        case .restorePrevious:
            applyRestore(element: element)
        case .nextDisplay:
            moveToAdjacentDisplay(offset: 1, element: element)
        case .previousDisplay:
            moveToAdjacentDisplay(offset: -1, element: element)
        case .tileWorkspaceAsGrid:
            tileWorkspaceAsGrid()
        case .cascadeWorkspace:
            cascadeWorkspace()
        case .columnsWorkspace:
            tileWorkspaceAsColumns()
        case .rowsWorkspace:
            tileWorkspaceAsRows()
        case .moveWindowForwardInWorkspace:
            reorderFocusedWindowInWorkspace(direction: .forward, element: element)
        case .moveWindowBackwardInWorkspace:
            reorderFocusedWindowInWorkspace(direction: .backward, element: element)
        case .bringWindowToFrontInWorkspace:
            reorderFocusedWindowInWorkspace(direction: .toFront, element: element)
        case .sendWindowToBackInWorkspace:
            reorderFocusedWindowInWorkspace(direction: .toBack, element: element)
        case .focusNextWindowInWorkspace:
            cycleFocusInWorkspace(forward: true, from: element)
        case .focusPreviousWindowInWorkspace:
            cycleFocusInWorkspace(forward: false, from: element)
        case .showHelp:
            // Help is routed by CommandPalette.runSelected directly. If this
            // is ever called, it's a no-op.
            break
        default:
            applySingleWindowTile(command, element: element)
        }
    }

    // MARK: Focus cycling

    private func cycleFocusInWorkspace(forward: Bool, from element: AXUIElement?) {
        guard let activeId = WorkspaceManager.shared.activeWorkspaceId,
            let workspace = WorkspaceManager.shared.workspaces.first(where: {
                $0.id == activeId
            })
        else { return }
        let refs = workspace.assignedWindows
        guard !refs.isEmpty else { return }

        // Resolve each ref to a live session window so we can skip ones that
        // aren't currently open.
        let sessionPairs: [(ref: WindowRef, session: WindowTracker.SessionWindow)] =
            refs.compactMap { ref in
                if let session = WindowTracker.shared.sessionWindows[ref.id] {
                    return (ref, session)
                }
                return nil
            }
        guard !sessionPairs.isEmpty else { return }

        // Identify the currently-focused session window (prefer the stashed
        // element hash; fall back to WindowTracker's frontmost lookup).
        var currentIndex: Int? = nil
        if let element = element {
            let targetHash = CFHash(element)
            currentIndex = sessionPairs.firstIndex(where: {
                CFHash($0.session.axElement) == targetHash
            })
        }
        if currentIndex == nil, let frontmost = WindowTracker.shared.getFrontmostSessionWindow()
        {
            currentIndex = sessionPairs.firstIndex(where: { $0.session.id == frontmost.id })
        }

        let base = currentIndex ?? -1
        let count = sessionPairs.count
        let step = forward ? 1 : -1
        let nextIndex = ((base + step) % count + count) % count
        let target = sessionPairs[nextIndex].session
        NSLog(
            "[Deks] cycleFocusInWorkspace forward=\(forward) base=\(base) -> \(nextIndex) (\(target.appName))"
        )

        _ = WindowTracker.shared.showSessionWindow(target)
        _ = WindowTracker.shared.focusAndRaiseSessionWindow(target)
    }

    // MARK: Reorder within active workspace

    private enum ReorderDirection {
        case forward
        case backward
        case toFront
        case toBack
    }

    /// Reorder the focused Deks-tracked window within its active workspace's
    /// `assignedWindows` list, then persist. If the focused AX window has no
    /// matching session entry in the active workspace, this is a no-op.
    private func reorderFocusedWindowInWorkspace(
        direction: ReorderDirection, element: AXUIElement?
    ) {
        _ = element  // Reorder operates on Deks-tracked session windows, not raw AX.
        guard let focused = WindowTracker.shared.getFrontmostSessionWindow() else { return }
        guard let activeId = WorkspaceManager.shared.activeWorkspaceId else { return }
        guard
            let wsIndex = WorkspaceManager.shared.workspaces.firstIndex(where: {
                $0.id == activeId
            })
        else { return }

        var assigned = WorkspaceManager.shared.workspaces[wsIndex].assignedWindows
        guard let currentIndex = assigned.firstIndex(where: { $0.id == focused.id }) else {
            return
        }

        let targetIndex: Int
        switch direction {
        case .forward:
            targetIndex = max(0, currentIndex - 1)
        case .backward:
            targetIndex = min(assigned.count - 1, currentIndex + 1)
        case .toFront:
            targetIndex = 0
        case .toBack:
            targetIndex = assigned.count - 1
        }

        if targetIndex == currentIndex { return }

        let ref = assigned.remove(at: currentIndex)
        assigned.insert(ref, at: targetIndex)
        WorkspaceManager.shared.workspaces[wsIndex].assignedWindows = assigned
        WorkspaceManager.shared.saveWorkspaces()
    }

    // MARK: Single-window tiles

    private func applySingleWindowTile(_ command: LayoutCommand, element: AXUIElement?) {
        guard let element = element else {
            NSLog("[Deks] applySingleWindowTile: no focused window")
            return
        }
        guard let screen = screen(for: element) ?? NSScreen.main else {
            NSLog("[Deks] applySingleWindowTile: no screen")
            return
        }
        let visible = axRect(fromCocoa: screen.visibleFrame)
        let gap = currentGap()
        guard let rect = rectForTile(command, element: element, in: visible, gap: gap) else {
            NSLog("[Deks] applySingleWindowTile: rectForTile returned nil")
            return
        }
        NSLog(
            "[Deks] applySingleWindowTile \(command.rawValue) -> \(rect) (visible=\(visible), gap=\(gap))"
        )
        rememberCurrentFrame(of: element)
        setFrame(rect, for: element)
        raiseAndActivate(element)
    }

    /// Raise the window inside its app and make that app the frontmost, so
    /// the user can immediately run another command against it instead of
    /// having to click back into it.
    private func raiseAndActivate(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success {
            NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        }
    }

    private func rectForTile(
        _ command: LayoutCommand,
        element: AXUIElement,
        in visible: CGRect,
        gap: CGFloat
    ) -> CGRect? {
        switch command {
        case .leftHalf:
            return cell(in: visible, gap: gap, cols: 2, rows: 1, col: 0, row: 0)
        case .rightHalf:
            return cell(in: visible, gap: gap, cols: 2, rows: 1, col: 1, row: 0)
        case .topHalf:
            return cell(in: visible, gap: gap, cols: 1, rows: 2, col: 0, row: 0)
        case .bottomHalf:
            return cell(in: visible, gap: gap, cols: 1, rows: 2, col: 0, row: 1)
        case .topLeftQuarter:
            return cell(in: visible, gap: gap, cols: 2, rows: 2, col: 0, row: 0)
        case .topRightQuarter:
            return cell(in: visible, gap: gap, cols: 2, rows: 2, col: 1, row: 0)
        case .bottomLeftQuarter:
            return cell(in: visible, gap: gap, cols: 2, rows: 2, col: 0, row: 1)
        case .bottomRightQuarter:
            return cell(in: visible, gap: gap, cols: 2, rows: 2, col: 1, row: 1)
        case .leftThird:
            return cell(in: visible, gap: gap, cols: 3, rows: 1, col: 0, row: 0)
        case .centerThird:
            return cell(in: visible, gap: gap, cols: 3, rows: 1, col: 1, row: 0)
        case .rightThird:
            return cell(in: visible, gap: gap, cols: 3, rows: 1, col: 2, row: 0)
        case .leftTwoThirds:
            return cell(in: visible, gap: gap, cols: 3, rows: 1, col: 0, row: 0, colSpan: 2)
        case .rightTwoThirds:
            return cell(in: visible, gap: gap, cols: 3, rows: 1, col: 1, row: 0, colSpan: 2)
        case .maximize:
            return cell(in: visible, gap: gap, cols: 1, rows: 1, col: 0, row: 0)
        case .almostMaximize:
            let inset = min(visible.width, visible.height) * 0.04
            let base = cell(in: visible, gap: gap, cols: 1, rows: 1, col: 0, row: 0)
            return base.insetBy(dx: inset, dy: inset)
        case .center:
            return centeredRect(for: element, in: visible, gap: gap)
        default:
            return nil
        }
    }

    // MARK: Workspace-wide tiles

    private func tileWorkspaceAsGrid() {
        let elements = workspaceWindowElements()
        guard !elements.isEmpty, let screen = NSScreen.main else { return }
        let visible = axRect(fromCocoa: screen.visibleFrame)
        let gap = currentGap()
        let n = elements.count
        let cols = max(1, Int(ceil(sqrt(Double(n)))))
        let rows = max(1, Int(ceil(Double(n) / Double(cols))))

        for (index, element) in elements.enumerated() {
            let col = index % cols
            let row = index / cols
            rememberCurrentFrame(of: element)
            let rect = cell(
                in: visible, gap: gap, cols: cols, rows: rows, col: col, row: row)
            setFrame(rect, for: element)
        }
    }

    private func tileWorkspaceAsColumns() {
        let elements = workspaceWindowElements()
        guard !elements.isEmpty, let screen = NSScreen.main else { return }
        let visible = axRect(fromCocoa: screen.visibleFrame)
        let gap = currentGap()
        let n = elements.count
        for (index, element) in elements.enumerated() {
            rememberCurrentFrame(of: element)
            let rect = cell(in: visible, gap: gap, cols: n, rows: 1, col: index, row: 0)
            setFrame(rect, for: element)
        }
    }

    private func tileWorkspaceAsRows() {
        let elements = workspaceWindowElements()
        guard !elements.isEmpty, let screen = NSScreen.main else { return }
        let visible = axRect(fromCocoa: screen.visibleFrame)
        let gap = currentGap()
        let n = elements.count
        for (index, element) in elements.enumerated() {
            rememberCurrentFrame(of: element)
            let rect = cell(in: visible, gap: gap, cols: 1, rows: n, col: 0, row: index)
            setFrame(rect, for: element)
        }
    }

    private func cascadeWorkspace() {
        let elements = workspaceWindowElements()
        guard !elements.isEmpty, let screen = NSScreen.main else { return }
        let visible = axRect(fromCocoa: screen.visibleFrame)
        let gap = currentGap()
        let tileW = visible.width * 0.68
        let tileH = visible.height * 0.72
        let step: CGFloat = 32

        for (index, element) in elements.enumerated() {
            rememberCurrentFrame(of: element)
            let maxOffsetX = max(0, visible.width - tileW - gap * 2)
            let maxOffsetY = max(0, visible.height - tileH - gap * 2)
            let offset = CGFloat(index) * step
            let rect = CGRect(
                x: visible.minX + gap + min(offset, maxOffsetX),
                y: visible.minY + gap + min(offset, maxOffsetY),
                width: tileW,
                height: tileH
            )
            setFrame(rect, for: element)
        }
    }

    // MARK: Display moves

    private func moveToAdjacentDisplay(offset: Int, element: AXUIElement?) {
        guard let element = element else { return }
        guard let currentScreen = screen(for: element) else { return }
        let screens = NSScreen.screens
        guard screens.count > 1 else { return }
        guard let currentIndex = screens.firstIndex(of: currentScreen) else { return }
        let targetIndex =
            ((currentIndex + offset) % screens.count + screens.count) % screens.count
        let targetScreen = screens[targetIndex]

        guard let currentFrame = currentFrame(of: element) else { return }
        let currentVisible = axRect(fromCocoa: currentScreen.visibleFrame)
        let targetVisible = axRect(fromCocoa: targetScreen.visibleFrame)

        // Preserve relative position + size within the screen's visible frame.
        let relX = (currentFrame.minX - currentVisible.minX) / max(currentVisible.width, 1)
        let relY = (currentFrame.minY - currentVisible.minY) / max(currentVisible.height, 1)
        let relW = currentFrame.width / max(currentVisible.width, 1)
        let relH = currentFrame.height / max(currentVisible.height, 1)

        let newRect = CGRect(
            x: targetVisible.minX + relX * targetVisible.width,
            y: targetVisible.minY + relY * targetVisible.height,
            width: relW * targetVisible.width,
            height: relH * targetVisible.height
        )

        rememberCurrentFrame(of: element)
        setFrame(newRect, for: element)
    }

    // MARK: Restore

    private func applyRestore(element: AXUIElement?) {
        guard let element = element else { return }
        let key = hashKey(for: element)
        guard let prev = previousFrames[key] else { return }
        setFrame(prev, for: element)
        previousFrames.removeValue(forKey: key)
    }

    private func rememberCurrentFrame(of element: AXUIElement) {
        guard let current = currentFrame(of: element) else { return }
        previousFrames[hashKey(for: element)] = current
    }

    private func hashKey(for element: AXUIElement) -> CFHashCode {
        return CFHash(element)
    }

    // MARK: Geometry helpers

    /// Compute a tile rect for a (col, row) cell inside `visible`, leaving
    /// `gap` on every outside edge and between cells.
    private func cell(
        in visible: CGRect,
        gap: CGFloat,
        cols: Int,
        rows: Int,
        col: Int,
        row: Int,
        colSpan: Int = 1,
        rowSpan: Int = 1
    ) -> CGRect {
        let cols = max(1, cols)
        let rows = max(1, rows)
        let totalGapsX = gap * CGFloat(cols + 1)
        let totalGapsY = gap * CGFloat(rows + 1)
        let cellW = (visible.width - totalGapsX) / CGFloat(cols)
        let cellH = (visible.height - totalGapsY) / CGFloat(rows)
        let x = visible.minX + gap + CGFloat(col) * (cellW + gap)
        let y = visible.minY + gap + CGFloat(row) * (cellH + gap)
        let w = cellW * CGFloat(colSpan) + gap * CGFloat(max(0, colSpan - 1))
        let h = cellH * CGFloat(rowSpan) + gap * CGFloat(max(0, rowSpan - 1))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func centeredRect(for element: AXUIElement, in visible: CGRect, gap: CGFloat)
        -> CGRect
    {
        guard let current = currentFrame(of: element) else {
            return visible.insetBy(dx: gap, dy: gap)
        }
        let w = min(current.width, visible.width - gap * 2)
        let h = min(current.height, visible.height - gap * 2)
        return CGRect(
            x: visible.midX - w / 2,
            y: visible.midY - h / 2,
            width: w,
            height: h
        )
    }

    /// Convert a Cocoa rect (Y-up, origin bottom-left of primary display) to
    /// AX/Quartz coordinates (Y-down, origin top-left of primary display).
    private func axRect(fromCocoa cocoa: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return cocoa }
        let primaryHeight = primary.frame.height
        return CGRect(
            x: cocoa.minX,
            y: primaryHeight - cocoa.maxY,
            width: cocoa.width,
            height: cocoa.height
        )
    }

    // MARK: AX read/write

    private func focusedWindowElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // Skip Deks's own palette window so the palette doesn't move itself.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return nil
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
                == .success,
            let windowRef = windowRef
        else {
            return nil
        }
        return (windowRef as! AXUIElement)
    }

    private func currentFrame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
                == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
                == .success,
            let posRef = posRef, let sizeRef = sizeRef,
            CFGetTypeID(posRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Write a new frame to the AX element. Sets position → size → position
    /// so that apps which clamp size on position change settle to the right
    /// final frame (the standard tiling-manager trick).
    private func setFrame(_ frame: CGRect, for element: AXUIElement) {
        var position = CGPoint(x: frame.origin.x.rounded(), y: frame.origin.y.rounded())
        var size = CGSize(width: frame.width.rounded(), height: frame.height.rounded())

        var pos1Result: AXError = .failure
        var sizeResult: AXError = .failure
        var pos2Result: AXError = .failure

        if let posValue = AXValueCreate(.cgPoint, &position) {
            pos1Result = AXUIElementSetAttributeValue(
                element, kAXPositionAttribute as CFString, posValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            sizeResult = AXUIElementSetAttributeValue(
                element, kAXSizeAttribute as CFString, sizeValue)
        }
        if let posValue = AXValueCreate(.cgPoint, &position) {
            pos2Result = AXUIElementSetAttributeValue(
                element, kAXPositionAttribute as CFString, posValue)
        }

        NSLog(
            "[Deks] setFrame position=\(position), size=\(size), pos1=\(pos1Result.rawValue), size=\(sizeResult.rawValue), pos2=\(pos2Result.rawValue)"
        )
    }

    private func screen(for element: AXUIElement) -> NSScreen? {
        guard let frame = currentFrame(of: element) else { return NSScreen.main }
        guard let primary = NSScreen.screens.first else { return NSScreen.main }
        let primaryHeight = primary.frame.height
        let cocoaRect = CGRect(
            x: frame.minX,
            y: primaryHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        let center = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    // MARK: Preferences

    private func currentGap() -> CGFloat {
        CGFloat(max(0, Persistence.loadPreferences().windowGap))
    }

    private func workspaceWindowElements() -> [AXUIElement] {
        guard let activeId = WorkspaceManager.shared.activeWorkspaceId,
            let workspace = WorkspaceManager.shared.workspaces.first(where: {
                $0.id == activeId
            })
        else {
            return []
        }
        return workspace.assignedWindows.compactMap {
            WindowTracker.shared.sessionWindows[$0.id]?.axElement
        }
    }
}
