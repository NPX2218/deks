import Foundation
import AppKit
import ApplicationServices

@MainActor
class WindowTracker {
    static let shared = WindowTracker()
    
    struct SessionWindow {
        let id: UUID
        let axElement: AXUIElement
        let pid: pid_t
        let bundleID: String
        let appName: String
        let initialTitle: String
        
        var currentTitle: String {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &ref) == .success {
                return (ref as? String) ?? initialTitle
            }
            return initialTitle
        }
    }
    
    var sessionWindows: [UUID: SessionWindow] = [:]
    
    func synchronizeSession(workspaces: [Workspace]) {
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var activeElements = [AXUIElement]()
        
        for app in runningApps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)
            
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            guard result == .success, let axWindows = windowsRef as? [AXUIElement] else { continue }
            
            let bundleID = app.bundleIdentifier ?? ""
            let appName = app.localizedName ?? bundleID
            
            for window in axWindows {
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
                if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) != .success { continue }
                var size = CGSize.zero
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                if size.width <= 50 || size.height <= 50 { continue }
                
                var matchedID: UUID?
                for ws in workspaces {
                    if let ref = ws.assignedWindows.first(where: { $0.bundleID == bundleID && $0.windowTitle == title }) {
                        if sessionWindows[ref.id] == nil {
                            matchedID = ref.id
                            break
                        }
                    }
                }
                
                let id = matchedID ?? UUID()
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
            TrackedWindow(windowID: 0, ownerPID: $0.pid, bundleID: $0.bundleID, title: $0.currentTitle, appName: $0.appName, isOnScreen: true)
        }
    }
    
    @discardableResult
    func hideSessionWindow(_ sessionWin: SessionWindow) -> Bool {
        let value: CFTypeRef = kCFBooleanTrue as CFTypeRef
        AXUIElementSetAttributeValue(sessionWin.axElement, kAXMinimizedAttribute as CFString, value)
        return true
    }
    
    @discardableResult
    func showSessionWindow(_ sessionWin: SessionWindow) -> Bool {
        let value: CFTypeRef = kCFBooleanFalse as CFTypeRef
        AXUIElementSetAttributeValue(sessionWin.axElement, kAXMinimizedAttribute as CFString, value)
        return true
    }
    
    func getFrontmostSessionWindow() -> SessionWindow? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef) == .success {
            let focusedWin = winRef as! AXUIElement
            return sessionWindows.values.first(where: { CFEqual($0.axElement, focusedWin) })
        }
        return nil
    }
}
