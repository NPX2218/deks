import Foundation
import AppKit

struct Workspace: Codable, Identifiable {
    let id: UUID
    var name: String
    var color: WorkspaceColor
    var hotkey: HotkeyCombo?
    var assignedWindows: [WindowRef]
    var idleOptimization: Bool
    var lastActiveAt: Date
}

enum WorkspaceColor: String, Codable {
    case green, purple, coral, blue, amber, pink
}

struct WindowRef: Codable, Identifiable {
    let id: UUID
    var bundleID: String
    var windowTitle: String
    var matchRule: WindowMatchRule
}

enum WindowMatchRule: Codable {
    case exactTitle(String)
    case titleContains(String)
    case appOnly(String)
    case windowIndex(String, Int)
}

struct TrackedWindow {
    let id: UUID
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bundleID: String
    let title: String
    let appName: String
    let isOnScreen: Bool
}

struct HotkeyCombo: Codable, Equatable, Hashable {
    var modifiers: UInt // We will store raw value of NSEvent.ModifierFlags
    var keyCode: UInt16
}

struct Preferences: Codable {
    var defaultNewWindowBehavior: NewWindowBehavior
    var idleTimeoutMinutes: Int
}

enum NewWindowBehavior: String, Codable {
    case autoAssignToActive
    case prompt
    case floating
}
