import AppKit
import ApplicationServices
import CryptoKit
import Foundation

@MainActor
class WindowTracker {
    static let shared = WindowTracker()

    private func matches(ref: WindowRef, bundleID: String, title: String, windowIndex: Int) -> Bool {
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
        }
    }

    private func setBoolAttribute(_ element: AXUIElement, attribute: CFString, value: Bool) -> Bool
    {
        let cfValue: CFTypeRef = (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        let result = AXUIElementSetAttributeValue(element, attribute, cfValue)
        return result == .success
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

                // Filter out fake "ghost" accessibility elements (like Spotify's invisible background client workers)
                // Real visible macOS windows always have measurable standard geometric screen dimensions
                var sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
                    != .success
                {
                    continue
                }
                var size = CGSize.zero
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                if size.width <= 50 || size.height <= 50 { continue }

                var matchedID: UUID?
                for ws in workspaces {
                    if let ref = ws.assignedWindows.first(where: {
                        matches(ref: $0, bundleID: bundleID, title: title, windowIndex: appWindowIndex)
                    }) {
                        if sessionWindows[ref.id] == nil {
                            matchedID = ref.id
                            break
                        }
                    }
                }

                let id: UUID
                if let existing = matchedID {
                    id = existing
                } else {
                    let titleKey = "\(bundleID)|\(title)"
                    let occurrence = (titleOccurrences[titleKey] ?? 0) + 1
                    titleOccurrences[titleKey] = occurrence

                    var seed = "\(bundleID)|\(title)|\(occurrence)"
                    var candidate = stableWindowID(seed: seed)
                    var salt = 1

                    while sessionWindows[candidate] != nil {
                        seed = "\(bundleID)|\(title)|\(occurrence)|\(salt)"
                        candidate = stableWindowID(seed: seed)
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
                    initialTitle: title
                )
            }
        }

        let deadKeys = sessionWindows.keys.filter { key in
            let ax = sessionWindows[key]!.axElement
            return !activeElements.contains(where: { CFEqual(ax, $0) })
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
        return setBoolAttribute(
            sessionWin.axElement,
            attribute: kAXMinimizedAttribute as CFString,
            value: true
        )
    }

    @discardableResult
    func showSessionWindow(_ sessionWin: SessionWindow) -> Bool {
        return setBoolAttribute(
            sessionWin.axElement,
            attribute: kAXMinimizedAttribute as CFString,
            value: false
        )
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
        return mainSet && focusedSet && raised
    }

    func getFrontmostSessionWindow() -> SessionWindow? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef)
            == .success
        {
            let focusedWin = winRef as! AXUIElement
            return sessionWindows.values.first(where: { CFEqual($0.axElement, focusedWin) })
        }
        return nil
    }
}
