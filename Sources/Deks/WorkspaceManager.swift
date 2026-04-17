import AppKit
import Foundation

@MainActor
class WorkspaceManager {
    static let shared = WorkspaceManager()

    private enum AppFallbackPolicy {
        case hideOnly
        case launchNewInstance
    }

    var workspaces: [Workspace] = []
    var activeWorkspaceId: UUID?
    /// The workspace that was active immediately before the current one.
    /// Used by the quick switcher to implement ⌘Tab-style "tap and release to
    /// jump back to the previous workspace" behavior.
    private(set) var previousWorkspaceId: UUID?
    private var startupRebalanceInProgress = false
    private var startupRebalanceTask: Task<Void, Never>?
    private var manualOrganizationMode = false
    private var isDeksEnabled = true
    private var autoAssignerTimer: Timer?
    private var autoAssignerTickCount: Int = 0
    private let appLaunchTime = Date()
    private var knownSessionWindowIDs = Set<UUID>()
    private var didInitializeAutoAssignBaseline = false
    /// How often (in auto-assigner ticks, i.e. seconds) to capture the active
    /// workspace z-order so the stored order tracks live window reordering
    /// even when the user doesn't explicitly switch workspaces.
    private let zOrderCaptureTickInterval: Int = 3
    
    // Track recently detected background apps to prevent duplicate launches
    private var detectedBackgroundApps: [String: Date] = [:]
    private let backgroundAppCooldownSeconds: TimeInterval = 3.0
    private var nonMultiInstanceApps: Set<String> = []
    private var launchAttemptsByBundle: [String: [Date]] = [:]
    private let launchAttemptWindowSeconds: TimeInterval = 20.0
    private let maxLaunchAttemptsPerWindow = 2
    private var lastPolicyLogByBundle: [String: Date] = [:]
    private let policyLogCooldownSeconds: TimeInterval = 2.0
    private let appFallbackPolicies: [String: AppFallbackPolicy] = [
        // Spotify is effectively single-instance. Launch retries are noisy and unhelpful.
        "com.spotify.client": .hideOnly,

        // Browsers generally support clean multi-instance launches.
        "com.google.Chrome": .launchNewInstance,
        "com.brave.Browser": .launchNewInstance,
        "com.microsoft.edgemac": .launchNewInstance,
    ]

    // Grace period after startup to avoid glitchy enforcement
    private let startupGracePeriodSeconds: TimeInterval = 5.0
    // Hard lock: disable auto-assignment during app restore churn after launch.
    private let startupAutoAssignLockSeconds: TimeInterval = 20.0
    private var verboseDevLogsEnabled: Bool {
        ProcessInfo.processInfo.environment["DEKS_DEV_LOGS"] == "1"
            || UserDefaults.standard.bool(forKey: "deks.devLogs")
    }

    var isManualOrganizationModeEnabled: Bool {
        manualOrganizationMode
    }

    var isDeksCurrentlyEnabled: Bool {
        isDeksEnabled
    }

    private func devLog(_ event: String, metadata: [String: String] = [:]) {
        guard verboseDevLogsEnabled else { return }
        TelemetryManager.shared.record(event: event, level: "debug", metadata: metadata)
    }

    private func shouldEmitPolicyLog(for bundleID: String) -> Bool {
        if let last = lastPolicyLogByBundle[bundleID] {
            if Date().timeIntervalSince(last) < policyLogCooldownSeconds {
                return false
            }
        }
        lastPolicyLogByBundle[bundleID] = Date()
        return true
    }

    private func fallbackPolicy(for bundleID: String) -> AppFallbackPolicy {
        // Stable default: hide-only avoids launch storms and random tab restoration.
        guard UserDefaults.standard.bool(forKey: "deks.aggressiveInstanceLaunchEnabled") else {
            return .hideOnly
        }
        return appFallbackPolicies[bundleID] ?? .hideOnly
    }

    private func makeWindowRef(from session: WindowTracker.SessionWindow) -> WindowRef {
        let rule: WindowMatchRule
        if let windowNumber = session.windowNumber {
            rule = .windowNumber(session.bundleID, windowNumber)
        } else {
            rule = .exactTitle(session.currentTitle)
        }

        return WindowRef(
            id: session.id,
            bundleID: session.bundleID,
            windowTitle: session.currentTitle,
            matchRule: rule
        )
    }

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

    func reconcileUnassignedWindows(autoAssignOrphans: Bool = false) {
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

                        if let windowNumber = sessionWin.windowNumber {
                            if case .windowNumber(let bundle, let number) = updatedRef.matchRule,
                                bundle == ref.bundleID,
                                number == windowNumber
                            {
                                // Already the most stable matching rule.
                            } else {
                                updatedRef.matchRule = .windowNumber(ref.bundleID, windowNumber)
                                changed = true
                            }
                        }

                        if updatedRef.windowTitle != current {
                            updatedRef.windowTitle = current
                            if case .exactTitle = updatedRef.matchRule {
                                updatedRef.matchRule = .exactTitle(current)
                            }
                            changed = true
                        }
                        validRefs.append(updatedRef)
                    } else {
                        // Keep refs only during startup restore churn (or if pinned).
                        // After startup, stale refs should be removed so UI doesn't claim
                        // windows/tabs still exist when they do not.
                        let inStartupLock = Date().timeIntervalSince(appLaunchTime)
                            < startupAutoAssignLockSeconds
                        if ref.isPinned || inStartupLock {
                            validRefs.append(ref)
                        } else {
                            changed = true
                        }
                    }
                } else {
                    // Application is fully closed. Remove the stale ref so it
                    // doesn't linger in the workspace list. The window will be
                    // re-discovered and auto-assigned if the app is relaunched.
                    changed = true
                }
            }
            workspaces[i].assignedWindows = validRefs
        }

        // 2. Discover deeply unassigned Session elements.
        // Only auto-assign orphans when explicitly requested (e.g. from the
        // auto-assigner timer). During workspace switches this must be skipped
        // because hidden windows from other workspaces can appear as
        // "unassigned" due to ID drift, causing them to leak into the wrong
        // workspace.
        if autoAssignOrphans {
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
                    let reference = makeWindowRef(from: sessionWin)
                    workspaces[activeIndex].assignedWindows.append(reference)
                    changed = true
                }
            }
        }
        if changed { saveWorkspaces() }
    }

    private func captureDynamicZOrder(for workspaceId: UUID?) {
        guard let id = workspaceId, let wsIndex = workspaces.firstIndex(where: { $0.id == id })
        else { return }

        // Only match against windows assigned to this workspace. Matching across
        // all session windows can accidentally consume same-app windows from
        // other workspaces (same PID/title), which corrupts order persistence.
        let workspaceRefIDs = Set(workspaces[wsIndex].assignedWindows.map(\.id))
        if workspaceRefIDs.isEmpty { return }

        let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
        guard
            let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return }

        // Split the workspace's session windows into two pools:
        //
        //   • Reliable — has a stable CGWindowID from `_AXUIElementGetWindow`.
        //     These are ONLY ever matched by exact cgWindowID, never by
        //     title or PID heuristics.
        //   • Unreliable — the private symbol failed for this element
        //     (extremely rare with @_silgen_name bridging, but possible for
        //     unusual apps). These can still be matched via title/PID
        //     fallbacks as a best-effort.
        //
        // The split is critical: `CGWindowListCopyWindowInfo` returns every
        // on-screen window in the system (tooltips, popups, menu bar items)
        // and many of those share a PID with our real session windows. The
        // previous implementation let those stray CGWindow entries consume
        // real session windows via the PID-alone fallback, silently
        // corrupting z-order for every workspace that had a multi-window
        // app with any transient popup on screen.
        var reliableSessions: [WindowTracker.SessionWindow] = []
        var unreliableSessions: [WindowTracker.SessionWindow] = []
        for session in WindowTracker.shared.sessionWindows.values
        where workspaceRefIDs.contains(session.id) {
            if session.cgWindowID != nil {
                reliableSessions.append(session)
            } else {
                unreliableSessions.append(session)
            }
        }

        var orderedIds = [UUID]()
        var heuristicFallbackCount = 0

        for info in windowList {
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let title = info[kCGWindowName as String] as? String ?? ""
            let cgWindowNumber = (info[kCGWindowNumber as String] as? NSNumber).map {
                CGWindowID($0.uint32Value)
            }

            // 1. Preferred: exact CGWindowID match against the reliable pool.
            if let cgWindowNumber,
                let idx = reliableSessions.firstIndex(where: { $0.cgWindowID == cgWindowNumber })
            {
                let matchId = reliableSessions.remove(at: idx).id
                if !orderedIds.contains(matchId) { orderedIds.append(matchId) }
                continue
            }

            // 2 & 3. Heuristic fallbacks — ONLY against the unreliable pool.
            // Never match unrelated CGWindowList entries (tooltips, popups,
            // system menu items) against sessions that have a valid
            // cgWindowID, since their ordering is already handled above.
            if unreliableSessions.isEmpty { continue }

            if let idx = unreliableSessions.firstIndex(where: {
                $0.pid == pid && $0.currentTitle == title
            }) {
                let matchId = unreliableSessions.remove(at: idx).id
                if !orderedIds.contains(matchId) { orderedIds.append(matchId) }
                heuristicFallbackCount += 1
                continue
            }

            if let idx = unreliableSessions.firstIndex(where: { $0.pid == pid }) {
                let matchId = unreliableSessions.remove(at: idx).id
                if !orderedIds.contains(matchId) { orderedIds.append(matchId) }
                heuristicFallbackCount += 1
                continue
            }
        }

        if heuristicFallbackCount > 0 {
            devLog(
                "zorder_capture_heuristic_fallback",
                metadata: [
                    "workspaceId": id.uuidString,
                    "count": String(heuristicFallbackCount),
                    "unreliablePoolSize": String(unreliableSessions.count + heuristicFallbackCount),
                ]
            )
        }

        // Build deterministic order: observed front-to-back IDs first, then keep
        // any unmatched refs in their previous relative order.
        let existingRefs = workspaces[wsIndex].assignedWindows
        var byId: [UUID: WindowRef] = [:]
        for ref in existingRefs {
            byId[ref.id] = ref
        }

        var reordered: [WindowRef] = []
        reordered.reserveCapacity(existingRefs.count)

        for id in orderedIds {
            if let ref = byId[id] {
                reordered.append(ref)
            }
        }

        for ref in existingRefs where !orderedIds.contains(ref.id) {
            reordered.append(ref)
        }

        workspaces[wsIndex].assignedWindows = reordered
    }

    func persistActiveWorkspaceWindowOrder() {
        guard activeWorkspaceId != nil else { return }
        WindowTracker.shared.synchronizeSession(workspaces: workspaces)
        captureDynamicZOrder(for: activeWorkspaceId)
        saveWorkspaces()
    }

    private func applyWorkspaceVisibility(workspace: Workspace, focusTopWindow: Bool) {
        if workspace.assignedWindows.isEmpty {
            return
        }

        // 1. Hide everything not assigned to the target workspace.
        for sessionWin in WindowTracker.shared.sessionWindows.values {
            if !workspace.assignedWindows.contains(where: { $0.id == sessionWin.id }) {
                WindowTracker.shared.hideSessionWindow(sessionWin)
            }
        }

        // 2. Unminimize every window in this workspace in a tight batch, no
        // spacing — we rebuild z-order explicitly in steps 3 & 4, so we don't
        // depend on the unminimize ordering to establish stacking.
        var sessionWindowsInOrder: [WindowTracker.SessionWindow] = []
        for ref in workspace.assignedWindows {
            if let sessionWin = WindowTracker.shared.sessionWindows[ref.id] {
                _ = WindowTracker.shared.showSessionWindow(sessionWin)
                sessionWindowsInOrder.append(sessionWin)
            }
        }

        // 3. Rebuild INTRA-app z-order: raise each window back-to-front via
        // kAXRaise so that within each owning application's window stack,
        // our stored front-most window actually sits on top.
        for sessionWin in sessionWindowsInOrder.reversed() {
            _ = WindowTracker.shared.raiseSessionWindow(sessionWin)
        }

        // 4. Rebuild CROSS-app z-order by activating each owning app in
        // back-to-front order via NSRunningApplication.activate. This is the
        // critical step: kAXRaise only reorders windows within a single
        // app's internal stack — it cannot push one app behind another at
        // the system level. Without an explicit activate call here, the
        // cross-app stacking is whatever it happened to be before the
        // switch, so a VSCode-in-front / Safari-behind workspace might
        // restore with Safari on top just because Safari was last active.
        //
        // Each PID is activated once at its FRONTMOST occurrence. Processing
        // the unique PID list in reverse means the frontmost window's app
        // is activated last, ending up on top at the system level. For
        // workspaces where each app has a single window (the common case)
        // this produces a pixel-perfect cross-app z-order. Interleaved
        // same-app windows remain a known limitation since macOS only
        // orders windows at the app granularity without private SLS APIs.
        var seenPIDs = Set<pid_t>()
        var appsFrontToBack: [pid_t] = []
        for sessionWin in sessionWindowsInOrder {
            if seenPIDs.insert(sessionWin.pid).inserted {
                appsFrontToBack.append(sessionWin.pid)
            }
        }
        for pid in appsFrontToBack.reversed() {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            if #available(macOS 14.0, *) {
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }

        // 5. Focus-raise the top window so keyboard events route to it and
        // its app is guaranteed frontmost regardless of any race with the
        // cross-app activation above.
        if focusTopWindow,
            let topRef = workspace.assignedWindows.first,
            let topSession = WindowTracker.shared.sessionWindows[topRef.id]
        {
            _ = WindowTracker.shared.focusAndRaiseSessionWindow(topSession)
        }
    }

    func startStartupRebalance() {
        if manualOrganizationMode { return }
        guard let activeId = activeWorkspaceId else { return }
        startupRebalanceTask?.cancel()
        startupRebalanceInProgress = true
        TelemetryManager.shared.record(
            event: "startup_rebalance_started",
            metadata: ["activeWorkspace": activeId.uuidString]
        )

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
            TelemetryManager.shared.record(event: "startup_rebalance_completed")
            self.menuBarRefreshIfNeeded()
        }
    }

    private func menuBarRefreshIfNeeded() {
        MenuBarManager.shared.updateTitle()
        if ConfigPanelController.shared.window?.isVisible == true {
            ConfigPanelController.shared.reload()
        }
    }

    func switchTo(workspaceId: UUID, force: Bool = false, source: String = "unknown") {
        if manualOrganizationMode && !force {
            TelemetryManager.shared.record(
                event: "workspace_switch_blocked_manual_mode",
                level: "debug",
                metadata: [
                    "workspaceId": workspaceId.uuidString,
                    "source": source,
                ]
            )
            return
        }

        TelemetryManager.shared.record(
            event: "workspace_switch_requested",
            level: "debug",
            metadata: [
                "workspaceId": workspaceId.uuidString,
                "source": source,
                "manualMode": manualOrganizationMode ? "true" : "false",
            ]
        )

        reconcileUnassignedWindows()
        captureDynamicZOrder(for: activeWorkspaceId)

        guard let wsIndex = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let workspace = workspaces[wsIndex]

        if !workspace.assignedWindows.isEmpty {
            applyWorkspaceVisibility(workspace: workspace, focusTopWindow: true)
        }

        // Remember the workspace we're leaving so ⌥Tab can jump back.
        if let currentActive = activeWorkspaceId, currentActive != workspaceId {
            previousWorkspaceId = currentActive
        }

        activeWorkspaceId = workspaceId
        workspaces[wsIndex].lastActiveAt = Date()
        saveWorkspaces()
        TelemetryManager.shared.record(
            event: "workspace_switched",
            metadata: [
                "workspaceId": workspaceId.uuidString,
                "workspaceName": workspace.name,
                "source": source,
            ]
        )
        MenuBarManager.shared.updateTitle()
        HUDManager.shared.show(workspace: workspaces[wsIndex])
    }

    @discardableResult
    func seedActiveWorkspaceFromSessionIfNeeded() -> Int {
        guard let activeId = activeWorkspaceId,
            let activeIndex = workspaces.firstIndex(where: { $0.id == activeId })
        else { return 0 }

        if !workspaces[activeIndex].assignedWindows.isEmpty {
            return 0
        }

        // Only seed automatically when there are no assignments anywhere yet.
        let hasAssignments = workspaces.contains { !$0.assignedWindows.isEmpty }
        if hasAssignments {
            return 0
        }

        WindowTracker.shared.synchronizeSession(workspaces: workspaces)

        let blacklist = Set([
            "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
            "com.neelbansal.deks", "com.apple.loginwindow", "",
        ])

        var added = 0
        for session in WindowTracker.shared.sessionWindows.values {
            if blacklist.contains(session.bundleID.lowercased()) {
                continue
            }

            let ref = makeWindowRef(from: session)
            workspaces[activeIndex].assignedWindows.append(ref)
            added += 1
        }

        if added > 0 {
            saveWorkspaces()
            TelemetryManager.shared.record(
                event: "workspace_seeded_from_session",
                metadata: [
                    "workspaceId": activeId.uuidString,
                    "windowCount": String(added),
                ]
            )
        }

        return added
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

    /// Move the currently focused window to the workspace at `index` (0-based)
    /// without switching workspaces. Hides the window immediately if the
    /// target workspace isn't the active one, and shows a brief HUD with the
    /// target workspace.
    @discardableResult
    func sendFocusedWindow(toWorkspaceAt index: Int) -> Bool {
        guard index >= 0, index < workspaces.count else { return false }
        guard let session = WindowTracker.shared.getFrontmostSessionWindow() else { return false }
        if session.appName == "Deks" { return false }

        // Skip work if the window is already at the front of the target
        // workspace — nothing for the user to observe.
        if workspaces[index].assignedWindows.first?.id == session.id {
            return false
        }

        let fallbackRef = makeWindowRef(from: session)
        workspaces = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: session.id,
            targetIndex: index,
            fallbackRef: fallbackRef
        )

        let targetId = workspaces[index].id
        saveWorkspaces()

        // If the window isn't in the active workspace anymore, hide it so the
        // user immediately sees it leave the current screen.
        if targetId != activeWorkspaceId {
            _ = WindowTracker.shared.hideSessionWindow(session)
        }

        TelemetryManager.shared.record(
            event: "window_sent_to_workspace",
            metadata: [
                "workspaceId": targetId.uuidString,
                "bundleID": session.bundleID,
            ]
        )

        HUDManager.shared.show(workspace: workspaces[index])
        MenuBarManager.shared.updateTitle()
        return true
    }

    /// Re-apply visibility for a single window based on the active workspace's
    /// assignment. Called from settings after a drag-drop so the user sees the
    /// window immediately hide or show to match the pending edit.
    func refreshVisibility(for windowID: UUID) {
        guard let sessionWin = WindowTracker.shared.sessionWindows[windowID] else { return }

        let belongsToActive = WorkspaceMutations.isWindowAssignedToActive(
            windowID: windowID,
            activeId: activeWorkspaceId,
            workspaces: workspaces
        )
        if belongsToActive {
            _ = WindowTracker.shared.showSessionWindow(sessionWin)
        } else {
            _ = WindowTracker.shared.hideSessionWindow(sessionWin)
        }
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

    @discardableResult
    func deleteWorkspace(id: UUID) -> Bool {
        guard let wsIndex = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        guard workspaces.count > 1 else { return false }

        let wasActive = (activeWorkspaceId == id)
        workspaces.remove(at: wsIndex)

        if wasActive {
            activeWorkspaceId = workspaces.first?.id
        } else if let active = activeWorkspaceId,
            !workspaces.contains(where: { $0.id == active })
        {
            activeWorkspaceId = workspaces.first?.id
        }

        saveWorkspaces()
        MenuBarManager.shared.updateTitle()
        return true
    }

    func isWindowPinned(_ windowId: UUID) -> Bool {
        for ws in workspaces {
            if let ref = ws.assignedWindows.first(where: { $0.id == windowId }) {
                return ref.isPinned
            }
        }
        return false
    }

    @discardableResult
    func togglePin(windowId: UUID) -> Bool {
        for wsIndex in workspaces.indices {
            if let refIndex = workspaces[wsIndex].assignedWindows.firstIndex(where: {
                $0.id == windowId
            }) {
                workspaces[wsIndex].assignedWindows[refIndex].isPinned.toggle()
                let pinned = workspaces[wsIndex].assignedWindows[refIndex].isPinned
                saveWorkspaces()
                TelemetryManager.shared.record(
                    event: pinned ? "window_pinned" : "window_unpinned",
                    metadata: [
                        "workspaceId": workspaces[wsIndex].id.uuidString,
                        "windowId": windowId.uuidString,
                    ]
                )
                return pinned
            }
        }
        return false
    }

    @discardableResult
    func quitAppAndRemoveAssignments(bundleID: String) -> Bool {
        let ownBundle = Bundle.main.bundleIdentifier
        if bundleID == ownBundle { return false }

        var terminatedAny = false
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == bundleID {
            if app.terminate() {
                terminatedAny = true
            }
        }

        var removedCount = 0
        for i in 0..<workspaces.count {
            let before = workspaces[i].assignedWindows.count
            workspaces[i].assignedWindows.removeAll { $0.bundleID == bundleID }
            removedCount += (before - workspaces[i].assignedWindows.count)
        }

        if removedCount > 0 {
            saveWorkspaces()
            MenuBarManager.shared.updateTitle()
            if ConfigPanelController.shared.window?.isVisible == true {
                ConfigPanelController.shared.reload()
            }
        }

        TelemetryManager.shared.record(
            event: "app_quit_and_assignments_removed",
            level: "debug",
            metadata: [
                "bundleID": bundleID,
                "terminatedAny": terminatedAny ? "true" : "false",
                "removedRefs": String(removedCount),
            ]
        )

        return terminatedAny || removedCount > 0
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
        WindowTracker.shared.synchronizeSession(workspaces: workspaces)
        knownSessionWindowIDs = Set(WindowTracker.shared.sessionWindows.keys)
        didInitializeAutoAssignBaseline = true

        autoAssignerTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.isDeksEnabled else { return }
                self.autoAssignNewWindows()

                // Every few seconds, refresh the stored z-order of the
                // active workspace so the next switch restores the most
                // recent stacking. Without this, the stored order only
                // updates at switch time and can lag behind reality if the
                // user has been clicking between windows.
                self.autoAssignerTickCount += 1
                if self.autoAssignerTickCount >= self.zOrderCaptureTickInterval {
                    self.autoAssignerTickCount = 0
                    if !self.manualOrganizationMode,
                        let activeId = self.activeWorkspaceId
                    {
                        self.captureDynamicZOrder(for: activeId)
                    }
                }
            }
        }
    }

    private func stopAutoAssigner() {
        autoAssignerTimer?.invalidate()
        autoAssignerTimer = nil
    }

    func toggleDeksEnabled() {
        isDeksEnabled.toggle()
        
        if isDeksEnabled {
            // Re-enable: restart the auto-assigner
            startAutoAssigner()
            TelemetryManager.shared.record(
                event: "deks_enabled",
                level: "debug"
            )
        } else {
            // Disable: stop the auto-assigner
            stopAutoAssigner()
            restoreAllTrackedWindows()
            TelemetryManager.shared.record(
                event: "deks_disabled",
                level: "debug"
            )
        }
        
        // Show HUD feedback
        HUDManager.shared.showToggleFeedback(enabled: isDeksEnabled)
    }

    // Emergency recovery path: when Deks is disabled, unhide everything so users are never stuck.
    private func restoreAllTrackedWindows() {
        WindowTracker.shared.synchronizeSession(workspaces: workspaces)

        var pidsToUnhide = Set<pid_t>()
        for session in WindowTracker.shared.sessionWindows.values {
            pidsToUnhide.insert(session.pid)
            _ = WindowTracker.shared.showSessionWindow(session)
        }

        for pid in pidsToUnhide {
            NSRunningApplication(processIdentifier: pid)?.unhide()
        }
    }

    private func autoAssignNewWindows() {
        if startupRebalanceInProgress || manualOrganizationMode { return }

        guard let activeId = activeWorkspaceId,
            workspaces.first(where: { $0.id == activeId }) != nil
        else { return }

        WindowTracker.shared.synchronizeSession(workspaces: workspaces)

        // Prune stale refs for closed apps so they don't linger in workspace lists.
        pruneClosedAppRefs()

        // During startup/app-restore churn, only update baseline and do not assign anything.
        // This prevents restored windows/tabs from being pulled into the active workspace.
        let timeSinceLaunch = Date().timeIntervalSince(appLaunchTime)
        if timeSinceLaunch < startupAutoAssignLockSeconds {
            knownSessionWindowIDs.formUnion(WindowTracker.shared.sessionWindows.keys)
            return
        }

        if !didInitializeAutoAssignBaseline {
            knownSessionWindowIDs = Set(WindowTracker.shared.sessionWindows.keys)
            didInitializeAutoAssignBaseline = true
            return
        }

        let allSessions = WindowTracker.shared.sessionWindows.values
        var assignedIds = Set<UUID>()
        for ws in workspaces {
            for ref in ws.assignedWindows {
                assignedIds.insert(ref.id)
            }
        }

        var modified = false
        for session in allSessions {
            // Only auto-assign windows discovered after baseline initialization.
            // This prevents startup windows from being pulled into the active workspace.
            if !knownSessionWindowIDs.contains(session.id) {
                knownSessionWindowIDs.insert(session.id)
            } else {
                continue
            }

            if !assignedIds.contains(session.id) {
                // Must explicitly filter out background framework binaries
                let bundle = session.bundleID.lowercased()
                let excludedBundles = [
                    "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
                    "com.neelbansal.deks", "com.apple.loginwindow", "",
                ]
                if !excludedBundles.contains(bundle) {
                    let ref = makeWindowRef(from: session)
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

    /// Remove window refs whose app is no longer running and whose window
    /// is not in the current session. Called periodically by the auto-assigner.
    private func pruneClosedAppRefs() {
        let runningBundles = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        var pruned = false
        for i in 0..<workspaces.count {
            let before = workspaces[i].assignedWindows.count
            workspaces[i].assignedWindows.removeAll { ref in
                // Keep if the app is still running
                if runningBundles.contains(ref.bundleID) { return false }
                // Keep if the window is still in the live session
                if WindowTracker.shared.sessionWindows[ref.id] != nil { return false }
                // Otherwise the app was quit and the window is gone
                return true
            }
            if workspaces[i].assignedWindows.count != before { pruned = true }
        }
        if pruned {
            saveWorkspaces()
            menuBarRefreshIfNeeded()
        }
    }

    // Enforce that only active workspace windows remain visible.
    // When a background window tries to show, launch a new instance instead.
    private func enforceActiveWorkspaceVisibility() {
        guard !manualOrganizationMode,
            let activeId = activeWorkspaceId,
            let activeIndex = workspaces.firstIndex(where: { $0.id == activeId })
        else { return }

        let timeSinceLaunch = Date().timeIntervalSince(appLaunchTime)
        if timeSinceLaunch < startupGracePeriodSeconds {
            return
        }

        let activeWorkspace = workspaces[activeIndex]
        let activeWindowIds = Set(activeWorkspace.assignedWindows.map { $0.id })
        let activeAppBundles = Set(activeWorkspace.assignedWindows.compactMap { ref in
            WindowTracker.shared.sessionWindows[ref.id]?.bundleID
        })

        // Get the frontmost app
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let frontmostBundle = frontmostApp.bundleIdentifier
        else { return }

        // Check if frontmost app has any windows outside the active workspace
        let frontmostAppSessions = WindowTracker.shared.sessionWindows.values.filter {
            $0.bundleID == frontmostBundle
        }

        for sessionWin in frontmostAppSessions {
            // If this window is NOT in the active workspace
            if !activeWindowIds.contains(sessionWin.id) {
                // Hide it
                WindowTracker.shared.hideSessionWindow(sessionWin)

                let fallbackPolicy = fallbackPolicy(for: frontmostBundle)
                guard fallbackPolicy == .launchNewInstance else {
                    if shouldEmitPolicyLog(for: frontmostBundle) {
                        devLog(
                            "policy_hide_only_applied",
                            metadata: [
                                "bundleID": frontmostBundle,
                                "windowId": sessionWin.id.uuidString,
                            ]
                        )
                    }
                    continue
                }

                // If the app isn't already in the active workspace, launch a new instance
                if !activeAppBundles.contains(frontmostBundle)
                    && shouldLaunchNewInstance(for: frontmostBundle)
                {
                    devLog(
                        "launch_new_instance_requested",
                        metadata: [
                            "bundleID": frontmostBundle,
                            "source": "enforceActiveWorkspaceVisibility",
                        ]
                    )
                    launchNewInstance(bundleID: frontmostBundle)
                }
            }
        }
    }

    private func shouldLaunchNewInstance(for bundleID: String) -> Bool {
        if nonMultiInstanceApps.contains(bundleID) {
            devLog(
                "launch_new_instance_skipped_non_multi_instance",
                metadata: ["bundleID": bundleID]
            )
            return false
        }

        let now = Date()
        var attempts = launchAttemptsByBundle[bundleID] ?? []
        attempts = attempts.filter { now.timeIntervalSince($0) < launchAttemptWindowSeconds }
        launchAttemptsByBundle[bundleID] = attempts

        if attempts.count >= maxLaunchAttemptsPerWindow {
            nonMultiInstanceApps.insert(bundleID)
            devLog(
                "launch_new_instance_quarantined_storm_protection",
                metadata: [
                    "bundleID": bundleID,
                    "attemptsInWindow": String(attempts.count),
                    "windowSeconds": String(launchAttemptWindowSeconds),
                ]
            )
            TelemetryManager.shared.record(
                event: "launch_storm_quarantined",
                level: "warning",
                metadata: [
                    "bundleID": bundleID,
                    "attemptsInWindow": String(attempts.count),
                    "windowSeconds": String(launchAttemptWindowSeconds),
                ]
            )
            return false
        }

        if let lastDetected = detectedBackgroundApps[bundleID] {
            let timeSince = Date().timeIntervalSince(lastDetected)
            if timeSince < backgroundAppCooldownSeconds {
                devLog(
                    "launch_new_instance_skipped_cooldown",
                    metadata: [
                        "bundleID": bundleID,
                        "cooldownSeconds": String(backgroundAppCooldownSeconds),
                    ]
                )
                return false
            }
        }
        return true
    }

    private func launchNewInstance(bundleID: String) {
        let now = Date()
        detectedBackgroundApps[bundleID] = now

        var attempts = launchAttemptsByBundle[bundleID] ?? []
        attempts = attempts.filter { now.timeIntervalSince($0) < launchAttemptWindowSeconds }
        attempts.append(now)
        launchAttemptsByBundle[bundleID] = attempts

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            devLog("launch_new_instance_app_url_not_found", metadata: ["bundleID": bundleID])
            return
        }

        let previousPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == bundleID }
                .map { $0.processIdentifier }
        )

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true

        // First try native API, then fallback to open -n.
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) {
            [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if error != nil {
                    self.devLog(
                        "launch_new_instance_native_api_failed_fallback_open_n",
                        metadata: [
                            "bundleID": bundleID,
                            "error": error?.localizedDescription ?? "unknown",
                        ]
                    )
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    process.arguments = ["-n", appURL.path]
                    _ = try? process.run()
                }

                // Verify a new process actually appeared; if not, app is single-instance.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let currentPIDs = Set(
                    NSWorkspace.shared.runningApplications
                        .filter { $0.bundleIdentifier == bundleID }
                        .map { $0.processIdentifier }
                )

                let createdNewProcess = !currentPIDs.subtracting(previousPIDs).isEmpty
                if !createdNewProcess {
                    self.nonMultiInstanceApps.insert(bundleID)
                    self.devLog(
                        "launch_new_instance_no_new_pid_detected",
                        metadata: ["bundleID": bundleID]
                    )
                    TelemetryManager.shared.record(
                        event: "app_single_instance_detected",
                        level: "debug",
                        metadata: ["bundleID": bundleID]
                    )
                } else {
                    self.devLog(
                        "launch_new_instance_pid_detected",
                        metadata: ["bundleID": bundleID]
                    )
                    TelemetryManager.shared.record(
                        event: "launched_new_app_instance",
                        level: "debug",
                        metadata: ["bundleID": bundleID]
                    )
                }
            }
        }
    }

    func setManualOrganizationMode(_ enabled: Bool) {
        guard manualOrganizationMode != enabled else { return }
        manualOrganizationMode = enabled

        if enabled {
            startupRebalanceTask?.cancel()
            startupRebalanceTask = nil
            startupRebalanceInProgress = false
        }

        TelemetryManager.shared.record(
            event: enabled ? "manual_organization_started" : "manual_organization_finished",
            level: "debug"
        )
    }

    // Automatically binds global Control+(1-9) hotkeys to jump between workspaces.
    func registerAutomaticHotkeys() {
        HotkeyManager.shared.resetAllHotkeys()

        // macOS Carbon key mapping for layout-independent hardware numbers 1 through 9
        let baseKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        let prefs = Persistence.loadPreferences()
        let workspaceModifiers: UInt
        switch prefs.workspaceSwitchModifier {
        case .control:
            workspaceModifiers = NSEvent.ModifierFlags([.control]).rawValue
        case .option:
            workspaceModifiers = NSEvent.ModifierFlags([.option]).rawValue
        case .command:
            workspaceModifiers = NSEvent.ModifierFlags([.command]).rawValue
        }
        let quickSwitcherModifiers = NSEvent.ModifierFlags([.option]).rawValue

        // Switch-to-workspace hotkeys (user-configurable modifier + digit).
        for (index, ws) in workspaces.enumerated() {
            if index < baseKeyCodes.count {
                let combo = HotkeyCombo(modifiers: workspaceModifiers, keyCode: baseKeyCodes[index])
                HotkeyManager.shared.register(hotkey: combo, for: ws.id)
            }
        }

        // Send-current-window-to-workspace hotkeys (⌃⇧1 … ⌃⇧9). Moves the
        // frontmost window into the Nth workspace without switching. Uses a
        // stable modifier combination so it doesn't clash with the
        // user-configurable switch modifier above unless they also pick
        // Control+Shift, which is fine because the digit action is unambiguous.
        let sendModifiers = NSEvent.ModifierFlags([.control, .shift]).rawValue
        for (index, _) in workspaces.enumerated() {
            if index < baseKeyCodes.count {
                let combo = HotkeyCombo(modifiers: sendModifiers, keyCode: baseKeyCodes[index])
                let capturedIndex = index
                HotkeyManager.shared.registerGlobalCallback(hotkey: combo) {
                    WorkspaceManager.shared.sendFocusedWindow(toWorkspaceAt: capturedIndex)
                }
            }
        }

        // Quick Switcher (⌥Tab forward, ⌥⇧Tab backward) — hold ⌥, tap Tab to
        // cycle, release ⌥ to commit, Esc to cancel.
        let optionTab = HotkeyCombo(modifiers: quickSwitcherModifiers, keyCode: 48)
        HotkeyManager.shared.registerGlobalCallback(hotkey: optionTab) {
            QuickSwitcher.shared.activateHold(forward: true)
        }

        let optionShiftTab = HotkeyCombo(
            modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue,
            keyCode: 48
        )
        HotkeyManager.shared.registerGlobalCallback(hotkey: optionShiftTab) {
            QuickSwitcher.shared.activateHold(forward: false)
        }

        // Create and switch to a new workspace (Control + Shift + N).
        let controlShiftN = HotkeyCombo(
            modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue,
            keyCode: 45
        )
        HotkeyManager.shared.registerGlobalCallback(hotkey: controlShiftN) {
            let count = WorkspaceManager.shared.workspaces.count
            let ws = WorkspaceManager.shared.createWorkspace(
                name: "Workspace \(count + 1)",
                color: .purple
            )
            WorkspaceManager.shared.switchTo(
                workspaceId: ws.id,
                force: true,
                source: "hotkey_new_workspace"
            )
        }

        // Toggle Deks on/off (Control + Shift + D)
        let controlShiftD = HotkeyCombo(
            modifiers: NSEvent.ModifierFlags([.control, .shift]).rawValue,
            keyCode: 2  // D key
        )
        HotkeyManager.shared.registerGlobalCallback(hotkey: controlShiftD) {
            WorkspaceManager.shared.toggleDeksEnabled()
        }

        // Command palette (Control + Option + W) — Raycast-style window layout
        // commands. W for "Window". Keycode 13 is W. Avoids ⌃⌥Space which
        // macOS reserves for "Select next input source".
        let controlOptionW = HotkeyCombo(
            modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
            keyCode: 13
        )
        HotkeyManager.shared.registerGlobalCallback(hotkey: controlOptionW) {
            CommandPalette.shared.toggle()
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
