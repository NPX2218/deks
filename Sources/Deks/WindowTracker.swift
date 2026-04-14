import AppKit
import ApplicationServices
import CryptoKit
import Darwin
import Foundation

extension Notification.Name {
    static let windowOperationTelemetryChanged = Notification.Name(
        "windowOperationTelemetryChanged")
}

// MARK: - Private AX ↔ CG bridge
//
// `_AXUIElementGetWindow` is an undocumented but widely used symbol (Yabai,
// Amethyst, Rectangle all rely on it) that returns the CGWindowID for an
// AXUIElement. We need it because the public `AXWindowNumber` attribute
// uses a different number space than `kCGWindowNumber` from
// CGWindowListCopyWindowInfo, so matching AX windows to the CG window
// list without this function requires unreliable title/PID heuristics.
//
// Resolved via `@_silgen_name` so the linker binds to it directly at build
// time. An earlier version of this file used `dlsym`, which silently failed
// on every call (the macOS dlsym underscore-handling is subtle and our
// lookup was returning nil 100% of the time, sending every z-order capture
// through the title/PID fallback). `@_silgen_name` is how every other Swift
// window manager bridges this symbol and is guaranteed-correct.

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Returns the CGWindowID for an AX element, or nil if the lookup fails.
/// The returned value is stable for the lifetime of the window and matches
/// `kCGWindowNumber` from CGWindowListCopyWindowInfo.
func cgWindowIDForAXElement(_ element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    let err = _AXUIElementGetWindow(element, &id)
    return err == .success ? id : nil
}

@MainActor
class WindowTracker {
    static let shared = WindowTracker()
    private let singleInstanceBundleIDs: Set<String> = [
        "com.spotify.client"
    ]

    struct OperationTelemetry {
        var hideFailures: Int = 0
        var showFailures: Int = 0
        var focusFailures: Int = 0
        var lastFailureAt: Date?
        var lastFailureDetail: String?

        var totalFailures: Int {
            hideFailures + showFailures + focusFailures
        }
    }

    private(set) var operationTelemetry = OperationTelemetry()
    private var lastFailureBySignature: [String: Date] = [:]
    private let failureLogThrottleSeconds: TimeInterval = 4.0

    private func recordFailure(operation: String, detail: String) {
        let signature = "\(operation)|\(detail)"
        if let last = lastFailureBySignature[signature],
            Date().timeIntervalSince(last) < failureLogThrottleSeconds
        {
            return
        }
        lastFailureBySignature[signature] = Date()

        switch operation {
        case "hide":
            operationTelemetry.hideFailures += 1
        case "show":
            operationTelemetry.showFailures += 1
        case "focus":
            operationTelemetry.focusFailures += 1
        default:
            break
        }

        operationTelemetry.lastFailureAt = Date()
        operationTelemetry.lastFailureDetail = detail
        TelemetryManager.shared.record(
            event: "window_operation_failure",
            level: "warning",
            metadata: [
                "operation": operation,
                "detail": detail,
            ]
        )
        NotificationCenter.default.post(name: .windowOperationTelemetryChanged, object: nil)
    }

    func telemetrySummary() -> String {
        let t = operationTelemetry
        if t.totalFailures == 0 {
            return "Window ops: healthy"
        }
        return
            "Window ops failures: \(t.totalFailures) (hide \(t.hideFailures), show \(t.showFailures), focus \(t.focusFailures))"
    }

    private func matches(
        ref: WindowRef,
        bundleID: String,
        title: String,
        windowIndex: Int,
        windowNumber: Int?
    ) -> Bool {
        guard ref.bundleID == bundleID else { return false }

        switch ref.matchRule {
        case .exactTitle(let storedTitle):
            return title == storedTitle
        case .titleContains(let fragment):
            guard !fragment.isEmpty else { return false }
            return title.localizedCaseInsensitiveContains(fragment)
        case .appOnly(let storedBundle):
            return storedBundle == bundleID
        case .windowIndex(let storedBundle, let storedIndex):
            return storedBundle == bundleID && storedIndex == windowIndex
        case .windowNumber(let storedBundle, let storedNumber):
            guard let windowNumber else { return false }
            return storedBundle == bundleID && storedNumber == windowNumber
        }
    }

    private func setBoolAttribute(_ element: AXUIElement, attribute: CFString, value: Bool) -> Bool
    {
        // Fast path: if attribute already equals the desired value, avoid a write and treat as success.
        if let current = boolAttributeValue(element, attribute: attribute), current == value {
            return true
        }

        let cfValue: CFTypeRef = (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        let result = AXUIElementSetAttributeValue(element, attribute, cfValue)
        if result == .success {
            return true
        }

        // Some apps return transient AX errors even when state eventually applies.
        if let currentAfter = boolAttributeValue(element, attribute: attribute),
            currentAfter == value
        {
            return true
        }

        return false
    }

    private func boolAttributeValue(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        if let number = ref as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private func stableWindowID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }

    struct SessionWindow {
        let id: UUID
        let axElement: AXUIElement
        let pid: pid_t
        let bundleID: String
        let appName: String
        let initialTitle: String
        let windowNumber: Int?
        /// Stable CGWindowID bridged from the AX element via
        /// `_AXUIElementGetWindow`. Used to produce reliable z-order matches
        /// against `CGWindowListCopyWindowInfo` results.
        let cgWindowID: CGWindowID?

        var currentTitle: String {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &ref)
                == .success
            {
                return (ref as? String) ?? initialTitle
            }
            return initialTitle
        }
    }

    var sessionWindows: [UUID: SessionWindow] = [:]

    func synchronizeSession(workspaces: [Workspace]) {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        var activeElements = [AXUIElement]()
        var titleOccurrences: [String: Int] = [:]

        for app in runningApps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)

            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                appElement, kAXWindowsAttribute as CFString, &windowsRef)
            guard result == .success, let axWindows = windowsRef as? [AXUIElement] else { continue }

            let bundleID = app.bundleIdentifier ?? ""
            let appName = app.localizedName ?? bundleID

            for (appWindowIndex, window) in axWindows.enumerated() {
                activeElements.append(window)

                if sessionWindows.values.contains(where: { CFEqual($0.axElement, window) }) {
                    continue
                }

                var titleRef: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String ?? ""

                var windowNumberRef: CFTypeRef?
                let windowNumberResult = AXUIElementCopyAttributeValue(
                    window,
                    "AXWindowNumber" as CFString,
                    &windowNumberRef
                )
                let windowNumber: Int?
                if windowNumberResult == .success,
                    let number = windowNumberRef as? NSNumber
                {
                    windowNumber = number.intValue
                } else {
                    windowNumber = nil
                }

                // Finder exposes a desktop pseudo-window with no title that cannot be restored like
                // a standard user window. Ignore it to prevent noisy restore failures.
                if bundleID == "com.apple.finder"
                    && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    continue
                }

                // Filter out fake "ghost" accessibility elements (like Spotify's invisible background client workers)
                // Real visible macOS windows always have measurable standard geometric screen dimensions
                var sizeRef: CFTypeRef?
                guard
                    AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
                        == .success,
                    let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
                else {
                    continue
                }
                var size = CGSize.zero
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                if size.width <= 50 || size.height <= 50 { continue }

                var matchedID: UUID?
                for ws in workspaces {
                    if let ref = ws.assignedWindows.first(where: {
                        matches(
                            ref: $0,
                            bundleID: bundleID,
                            title: title,
                            windowIndex: appWindowIndex,
                            windowNumber: windowNumber
                        )
                    }) {
                        if sessionWindows[ref.id] == nil {
                            matchedID = ref.id
                            break
                        }
                    }
                }

                // Fallback for single-instance apps whose window title/number can drift
                // across restart (Spotify). If exactly one unbound ref exists for this app,
                // rebind this live window to that saved ref id.
                if matchedID == nil,
                    singleInstanceBundleIDs.contains(bundleID)
                {
                    let candidates = workspaces
                        .flatMap { $0.assignedWindows }
                        .filter { $0.bundleID == bundleID && sessionWindows[$0.id] == nil }

                    if candidates.count == 1 {
                        matchedID = candidates[0].id
                    }
                }

                let id: UUID
                if let existing = matchedID {
                    id = existing
                } else {
                    let baseSeed: String
                    if let windowNumber {
                        baseSeed = "\(bundleID)|windowNumber:\(windowNumber)"
                    } else {
                        let titleKey = "\(bundleID)|\(title)"
                        let occurrence = (titleOccurrences[titleKey] ?? 0) + 1
                        titleOccurrences[titleKey] = occurrence
                        baseSeed = "\(bundleID)|\(title)|\(occurrence)"
                    }

                    var candidate = stableWindowID(seed: baseSeed)
                    var salt = 1

                    while sessionWindows[candidate] != nil {
                        let saltedSeed = "\(baseSeed)|\(salt)"
                        candidate = stableWindowID(seed: saltedSeed)
                        salt += 1
                    }

                    id = candidate
                }

                sessionWindows[id] = SessionWindow(
                    id: id,
                    axElement: window,
                    pid: pid,
                    bundleID: bundleID,
                    appName: appName,
                    initialTitle: title,
                    windowNumber: windowNumber,
                    cgWindowID: cgWindowIDForAXElement(window)
                )
            }
        }

        let deadKeys = sessionWindows.compactMap { key, win in
            activeElements.contains(where: { CFEqual(win.axElement, $0) }) ? nil : key
        }
        for k in deadKeys { sessionWindows.removeValue(forKey: k) }
    }

    func discoverWindows() -> [TrackedWindow] {
        return sessionWindows.values.map {
            TrackedWindow(
                id: $0.id, windowID: 0, ownerPID: $0.pid, bundleID: $0.bundleID,
                title: $0.currentTitle, appName: $0.appName, isOnScreen: true)
        }
    }

    @discardableResult
    func hideSessionWindow(_ sessionWin: SessionWindow) -> Bool {
        let success = setBoolAttribute(
            sessionWin.axElement,
            attribute: kAXMinimizedAttribute as CFString,
            value: true
        )
        if !success {
            recordFailure(
                operation: "hide", detail: "\(sessionWin.bundleID) / \(sessionWin.currentTitle)")
        }
        return success
    }

    @discardableResult
    func showSessionWindow(_ sessionWin: SessionWindow) -> Bool {
        let success = setBoolAttribute(
            sessionWin.axElement,
            attribute: kAXMinimizedAttribute as CFString,
            value: false
        )
        if !success {
            recordFailure(
                operation: "show", detail: "\(sessionWin.bundleID) / \(sessionWin.currentTitle)")
        }
        return success
    }

    /// Raise a window to the top of its app's stacking order without
    /// touching kAXMain/kAXFocused. Used by workspace restore to rebuild the
    /// z-order back-to-front: calling this for every window in reverse order
    /// produces a deterministic final stack regardless of unminimize animation
    /// timing.
    @discardableResult
    func raiseSessionWindow(_ sessionWin: SessionWindow) -> Bool {
        let status = AXUIElementPerformAction(
            sessionWin.axElement,
            kAXRaiseAction as CFString
        )
        let success = status == .success
        if !success {
            recordFailure(
                operation: "raise",
                detail: "\(sessionWin.bundleID) / \(sessionWin.currentTitle) [status=\(status.rawValue)]"
            )
        }
        return success
    }

    @discardableResult
    func focusAndRaiseSessionWindow(_ sessionWin: SessionWindow) -> Bool {
        let mainSet = setBoolAttribute(
            sessionWin.axElement,
            attribute: kAXMainAttribute as CFString,
            value: true
        )
        let focusedSet = setBoolAttribute(
            sessionWin.axElement,
            attribute: kAXFocusedAttribute as CFString,
            value: true
        )
        let raised =
            AXUIElementPerformAction(sessionWin.axElement, kAXRaiseAction as CFString) == .success
        // Some apps refuse kAXMain/kAXFocused writes but still raise correctly.
        let success = raised || (mainSet && focusedSet)
        if !success {
            let detail =
                "\(sessionWin.bundleID) / \(sessionWin.currentTitle) [main=\(mainSet), focus=\(focusedSet), raise=\(raised)]"
            recordFailure(operation: "focus", detail: detail)
        }
        return success
    }

    func getFrontmostSessionWindow() -> SessionWindow? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &winRef
            ) == .success,
            let value = winRef, CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let focusedWin = value as! AXUIElement
        return sessionWindows.values.first(where: { CFEqual($0.axElement, focusedWin) })
    }
}
