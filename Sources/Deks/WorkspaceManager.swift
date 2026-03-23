import AppKit
import Foundation

@MainActor
class WorkspaceManager {
    static let shared = WorkspaceManager()

    var workspaces: [Workspace] = []
    var activeWorkspaceId: UUID?

    private init() {
        loadWorkspaces()
    }

    private func loadAppState() -> AppState? {
        let url = Persistence.appStateFileUrl()
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppState.self, from: data)
    }

    private func saveAppState() {
        let url = Persistence.appStateFileUrl()
        let state = AppState(activeWorkspaceId: activeWorkspaceId)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url)
        }
    }

    func createWorkspace(name: String, color: WorkspaceColor) -> Workspace {
        let ws = Workspace(
            id: UUID(),
            name: name,
            color: color,
            hotkey: nil,
            assignedWindows: [],
            idleOptimization: false,
            lastActiveAt: Date()
        )
        workspaces.append(ws)
        if activeWorkspaceId == nil || !workspaces.contains(where: { $0.id == activeWorkspaceId }) {
            activeWorkspaceId = ws.id
        }
        saveWorkspaces()
        return ws
    }

    func reconcileUnassignedWindows() {
        guard let activeId = activeWorkspaceId else { return }
        guard let activeIndex = workspaces.firstIndex(where: { $0.id == activeId }) else { return }

        WindowTracker.shared.synchronizeSession(workspaces: workspaces)

        var changed = false

        // 1. Cull closed windows & Sync Dynamic Titles
        let runningApps = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }

        for i in 0..<workspaces.count {
            var validRefs = [WindowRef]()
            for ref in workspaces[i].assignedWindows {
                let isAppRunning = runningApps.contains(ref.bundleID)

                if isAppRunning {
                    // It's actively executing under AppKit, does the window physically exist still?
                    if let sessionWin = WindowTracker.shared.sessionWindows[ref.id] {
                        var updatedRef = ref
                        let current = sessionWin.currentTitle
                        if updatedRef.windowTitle != current {
                            updatedRef.windowTitle = current
                            updatedRef.matchRule = .exactTitle(current)  // Ensure JSON reboot matching is locked sequentially
                            changed = true
                        }
                        validRefs.append(updatedRef)
                    } else {
                        // The app is running, but the specific window is fully gone (User closed the specific tab natively). Frame shift delete.
                        changed = true
                    }
                } else {
                    // Application is fully closed offline natively. Retain in config so workspaces restore automatically later on relaunch.
                    validRefs.append(ref)
                }
            }
            workspaces[i].assignedWindows = validRefs
        }

        // 2. Discover deeply unassigned Session elements
        for sessionWin in WindowTracker.shared.sessionWindows.values
        where sessionWin.appName != "Deks" {
            var isAssignedAnywhere = false
            for ws in workspaces {
                if ws.assignedWindows.contains(where: { $0.id == sessionWin.id }) {
                    isAssignedAnywhere = true
                    break
                }
            }
            if !isAssignedAnywhere {
                // Not mapped anywhere! Assign via stable session id
                let reference = WindowRef(
                    id: sessionWin.id,
                    bundleID: sessionWin.bundleID,
                    windowTitle: sessionWin.currentTitle,
                    matchRule: .exactTitle(sessionWin.currentTitle)  // Kept for serialization legacy if restarted
                )
                workspaces[activeIndex].assignedWindows.append(reference)
                changed = true
            }
        }
        if changed { saveWorkspaces() }
    }

    private func captureDynamicZOrder(for workspaceId: UUID?) {
        guard let id = workspaceId, let wsIndex = workspaces.firstIndex(where: { $0.id == id })
        else { return }
        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard
            let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return }

        var availableSessions = Array(WindowTracker.shared.sessionWindows.values)
        var orderedIds = [UUID]()

        for info in windowList {
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let title = info[kCGWindowName as String] as? String ?? ""

            var matchedIndex: Int?
            // 1. Exact match Title + PID
            if let idx = availableSessions.firstIndex(where: {
                $0.pid == pid && $0.currentTitle == title
            }) {
                matchedIndex = idx
            }
            // 2. Fallback to arbitrary PID for identical instances (e.g. Brave) missing CG names
            else if let idx = availableSessions.firstIndex(where: { $0.pid == pid }) {
                matchedIndex = idx
            }

            if let idx = matchedIndex {
                let matchId = availableSessions.remove(at: idx).id
                if workspaces[wsIndex].assignedWindows.contains(where: { $0.id == matchId }),
                    !orderedIds.contains(matchId)
                {
                    orderedIds.append(matchId)
                }
            }
        }

        workspaces[wsIndex].assignedWindows.sort { a, b in
            let idxA = orderedIds.firstIndex(of: a.id) ?? 999
            let idxB = orderedIds.firstIndex(of: b.id) ?? 999
            return idxA < idxB
        }
    }

    func switchTo(workspaceId: UUID) {
        reconcileUnassignedWindows()
        captureDynamicZOrder(for: activeWorkspaceId)

        guard let wsIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let workspace = workspaces[wsIndex]

        // Pass 1: Instantly hide all windows entirely unrelated to this new Workspace
        for sessionWin in WindowTracker.shared.sessionWindows.values {
            if !workspace.assignedWindows.contains(where: { $0.id == sessionWin.id }) {
                WindowTracker.shared.hideSessionWindow(sessionWin)
            }
        }

        // Pass 1.5: Batch unhide parent applications universally exactly once to completely eradicate sequential stutter hooks
        var pidsToUnhide = Set<pid_t>()
        for ref in workspace.assignedWindows {
            if let win = WindowTracker.shared.sessionWindows[ref.id] {
                pidsToUnhide.insert(win.pid)
            }
        }
        for pid in pidsToUnhide {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }

        // Pass 2: Iteratively un-minimize and restore assigned windows specifically from BACK to FRONT relying on our mathematical Z-order array!
        for ref in workspace.assignedWindows.reversed() {
            if let sessionWin = WindowTracker.shared.sessionWindows[ref.id] {
                let shown = WindowTracker.shared.showSessionWindow(sessionWin)
                let focused = WindowTracker.shared.focusAndRaiseSessionWindow(sessionWin)
                if !shown || !focused {
                    print(
                        "Warning: Failed to fully restore window \(sessionWin.bundleID) / \(sessionWin.currentTitle)"
                    )
                }

                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            }
        }

        activeWorkspaceId = workspaceId
        workspaces[wsIndex].lastActiveAt = Date()
        saveWorkspaces()
        MenuBarManager.shared.updateTitle()
        HUDManager.shared.show(workspace: workspaces[wsIndex])
    }

    func assignWindow(_ tracked: TrackedWindow, to workspaceId: UUID) {
        guard let wsIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let reference = WindowRef(
            id: tracked.id,
            bundleID: tracked.bundleID,
            windowTitle: tracked.title,
            matchRule: .exactTitle(tracked.title)
        )
        workspaces[wsIndex].assignedWindows.append(reference)
        saveWorkspaces()
    }

    private func loadWorkspaces() {
        let url = Persistence.workspacesFileUrl()
        if let data = try? Data(contentsOf: url),
            let list = try? JSONDecoder().decode([Workspace].self, from: data)
        {
            self.workspaces = list
            let persistedActiveId = loadAppState()?.activeWorkspaceId
            if let persistedActiveId,
                list.contains(where: { $0.id == persistedActiveId })
            {
                self.activeWorkspaceId = persistedActiveId
            } else {
                self.activeWorkspaceId = list.first?.id
            }
        } else {
            self.activeWorkspaceId = loadAppState()?.activeWorkspaceId
        }
        registerAutomaticHotkeys()
    }

    // Auto-assign logic to continually pull new tabs/windows to the active workspace cleanly
    func startAutoAssigner() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.autoAssignNewWindows()
            }
        }
    }

    private func autoAssignNewWindows() {
        guard let activeId = activeWorkspaceId,
            workspaces.first(where: { $0.id == activeId }) != nil
        else { return }

        WindowTracker.shared.synchronizeSession(workspaces: workspaces)
        let allSessions = WindowTracker.shared.sessionWindows.values
        var assignedIds = Set<UUID>()
        for ws in workspaces {
            for ref in ws.assignedWindows {
                assignedIds.insert(ref.id)
            }
        }

        var modified = false
        for session in allSessions {
            if !assignedIds.contains(session.id) {
                // Must explicitly filter out background framework binaries
                let bundle = session.bundleID.lowercased()
                let blacklist = [
                    "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
                    "com.neelbansal.deks", "com.apple.loginwindow", "",
                ]
                if !blacklist.contains(bundle) {
                    let ref = WindowRef(
                        id: session.id, bundleID: session.bundleID,
                        windowTitle: session.currentTitle,
                        matchRule: .exactTitle(session.currentTitle))
                    if let idx = workspaces.firstIndex(where: { $0.id == activeId }) {
                        workspaces[idx].assignedWindows.append(ref)
                        modified = true
                    }
                }
            }
        }

        if modified {
            saveWorkspaces()
            MenuBarManager.shared.updateTitle()
            if ConfigPanelController.shared.window?.isVisible == true {
                ConfigPanelController.shared.reload()
            }
        }
    }

    // Automatically binds global Option+(1-9) hotkeys to jump between workspaces!
    func registerAutomaticHotkeys() {
        // macOS Carbon key mapping for layout-independent hardware numbers 1 through 9
        let baseKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let modifiers = NSEvent.ModifierFlags([.option]).rawValue

        for (index, ws) in workspaces.enumerated() {
            if index < baseKeyCodes.count {
                let combo = HotkeyCombo(modifiers: modifiers, keyCode: baseKeyCodes[index])
                HotkeyManager.shared.register(hotkey: combo, for: ws.id)
            }
        }

        // Quick Switcher Map (Option + Tab)
        let optionTab = HotkeyCombo(modifiers: modifiers, keyCode: 48)
        HotkeyManager.shared.registerGlobalCallback(hotkey: optionTab) {
            QuickSwitcher.shared.show()
        }
    }

    func saveWorkspaces() {
        let url = Persistence.workspacesFileUrl()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(workspaces) {
            try? data.write(to: url)
        }
        saveAppState()
        registerAutomaticHotkeys()
    }
}
