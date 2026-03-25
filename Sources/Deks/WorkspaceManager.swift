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
    private var startupRebalanceInProgress = false
    private var startupRebalanceTask: Task<Void, Never>?
    private var manualOrganizationMode = false
    private var isDeksEnabled = true
    private var autoAssignerTimer: Timer?
    private let appLaunchTime = Date()
    private var knownSessionWindowIDs = Set<UUID>()
    private var didInitializeAutoAssignBaseline = false
    
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

        var availableSessions = WindowTracker.shared.sessionWindows.values
            .filter { workspaceRefIDs.contains($0.id) }
        var orderedIds = [UUID]()

        for info in windowList {
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let title = info[kCGWindowName as String] as? String ?? ""
            let cgWindowNumber = info[kCGWindowNumber as String] as? Int

            var matchedIndex: Int?
            // 1. Prefer exact PID + window number when available.
            if let cgWindowNumber,
                let idx = availableSessions.firstIndex(where: {
                    $0.pid == pid && $0.windowNumber == cgWindowNumber
                })
            {
                matchedIndex = idx
            }
            // 2. Fallback: exact Title + PID
            else if let idx = availableSessions.firstIndex(where: {
                $0.pid == pid && $0.currentTitle == title
            }) {
                matchedIndex = idx
            }
            // 3. Last fallback to arbitrary PID for identical instances (e.g. some Chromium windows with sparse metadata)
            else if let idx = availableSessions.firstIndex(where: { $0.pid == pid }) {
                matchedIndex = idx
            }

            if let idx = matchedIndex {
                let matchId = availableSessions.remove(at: idx).id
                if !orderedIds.contains(matchId) {
                    orderedIds.append(matchId)
                }
            }
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

        // Hide everything not in the target workspace.
        for sessionWin in WindowTracker.shared.sessionWindows.values {
            if !workspace.assignedWindows.contains(where: { $0.id == sessionWin.id }) {
                WindowTracker.shared.hideSessionWindow(sessionWin)
            }
        }

        // Restore windows in back-to-front order so they stack correctly.
        // assignedWindows[0] is the frontmost, so reversed() gives us
        // back windows first, building up to the front.
        for ref in workspace.assignedWindows.reversed() {
            if let sessionWin = WindowTracker.shared.sessionWindows[ref.id] {
                _ = WindowTracker.shared.showSessionWindow(sessionWin)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
            }
        }

        // Raise the top window last so it ends up in front of everything.
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

        autoAssignerTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard self?.isDeksEnabled == true else { return }
                self?.autoAssignNewWindows()
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
