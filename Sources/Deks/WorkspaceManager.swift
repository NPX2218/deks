import AppKit
import Foundation

@MainActor
class WorkspaceManager {
    static let shared = WorkspaceManager()

    var workspaces: [Workspace] = []
    var activeWorkspaceId: UUID?
    private var startupRebalanceInProgress = false
    private var startupRebalanceTask: Task<Void, Never>?

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
                            if case .exactTitle = updatedRef.matchRule {
                                updatedRef.matchRule = .exactTitle(current)
                            }
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

    private func applyWorkspaceVisibility(workspace: Workspace, focusTopWindow: Bool) {
        // Hide everything not in the target workspace.
        for sessionWin in WindowTracker.shared.sessionWindows.values {
            if !workspace.assignedWindows.contains(where: { $0.id == sessionWin.id }) {
                WindowTracker.shared.hideSessionWindow(sessionWin)
            }
        }

        // Unhide parent apps once to reduce per-window restore jitter.
        var pidsToUnhide = Set<pid_t>()
        for ref in workspace.assignedWindows {
            if let win = WindowTracker.shared.sessionWindows[ref.id] {
                pidsToUnhide.insert(win.pid)
            }
        }
        for pid in pidsToUnhide {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }

        // Restore windows in back-to-front order.
        for (index, ref) in workspace.assignedWindows.reversed().enumerated() {
            if let sessionWin = WindowTracker.shared.sessionWindows[ref.id] {
                _ = WindowTracker.shared.showSessionWindow(sessionWin)
                if focusTopWindow && index == 0 {
                    _ = WindowTracker.shared.focusAndRaiseSessionWindow(sessionWin)
                }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            }
        }
    }

    func startStartupRebalance() {
        guard let activeId = activeWorkspaceId else { return }
        startupRebalanceTask?.cancel()
        startupRebalanceInProgress = true

        startupRebalanceTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Run a few passes to catch windows restored by apps slightly after login.
            for pass in 0..<6 {
                if Task.isCancelled { return }

                WindowTracker.shared.synchronizeSession(workspaces: self.workspaces)
                if let wsIndex = self.workspaces.firstIndex(where: { $0.id == activeId }) {
                    self.applyWorkspaceVisibility(
                        workspace: self.workspaces[wsIndex],
                        focusTopWindow: pass == 0
                    )
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            self.startupRebalanceInProgress = false
            self.startupRebalanceTask = nil
            self.menuBarRefreshIfNeeded()
        }
    }

    private func menuBarRefreshIfNeeded() {
        MenuBarManager.shared.updateTitle()
        if ConfigPanelController.shared.window?.isVisible == true {
            ConfigPanelController.shared.reload()
        }
    }

    func switchTo(workspaceId: UUID) {
        reconcileUnassignedWindows()
        captureDynamicZOrder(for: activeWorkspaceId)

        guard let wsIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let workspace = workspaces[wsIndex]

        applyWorkspaceVisibility(workspace: workspace, focusTopWindow: true)

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

    func renameWorkspace(id: UUID, to newName: String) {
        guard let wsIndex = workspaces.firstIndex(where: { $0.id == id }) else { return }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled Workspace" : trimmed
        guard workspaces[wsIndex].name != finalName else { return }

        workspaces[wsIndex].name = finalName
        saveWorkspaces()

        if activeWorkspaceId == id {
            MenuBarManager.shared.updateTitle()
        }
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
        if startupRebalanceInProgress { return }

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
            menuBarRefreshIfNeeded()
        }
    }

    // Automatically binds global Control+(1-9) hotkeys to jump between workspaces.
    func registerAutomaticHotkeys() {
        HotkeyManager.shared.resetAllHotkeys()

        // macOS Carbon key mapping for layout-independent hardware numbers 1 through 9
        let baseKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let workspaceModifiers = NSEvent.ModifierFlags([.control]).rawValue
        let quickSwitcherModifiers = NSEvent.ModifierFlags([.option]).rawValue

        for (index, ws) in workspaces.enumerated() {
            if index < baseKeyCodes.count {
                let combo = HotkeyCombo(modifiers: workspaceModifiers, keyCode: baseKeyCodes[index])
                HotkeyManager.shared.register(hotkey: combo, for: ws.id)
            }
        }

        // Quick Switcher Map (Option + Tab)
        let optionTab = HotkeyCombo(modifiers: quickSwitcherModifiers, keyCode: 48)
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
