import AppKit
import Foundation

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
    case green, purple, coral, blue, amber, pink, red, mint
}

struct WindowRef: Codable, Identifiable {
    let id: UUID
    var bundleID: String
    var windowTitle: String
    var matchRule: WindowMatchRule
    var isPinned: Bool

    init(
        id: UUID,
        bundleID: String,
        windowTitle: String,
        matchRule: WindowMatchRule,
        isPinned: Bool = false
    ) {
        self.id = id
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.matchRule = matchRule
        self.isPinned = isPinned
    }

    enum CodingKeys: String, CodingKey {
        case id
        case bundleID
        case windowTitle
        case matchRule
        case isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        windowTitle = try container.decode(String.self, forKey: .windowTitle)
        matchRule = try container.decode(WindowMatchRule.self, forKey: .matchRule)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(windowTitle, forKey: .windowTitle)
        try container.encode(matchRule, forKey: .matchRule)
        try container.encode(isPinned, forKey: .isPinned)
    }
}

enum WindowMatchRule: Codable {
    case exactTitle(String)
    case titleContains(String)
    case appOnly(String)
    case windowIndex(String, Int)
    case windowNumber(String, Int)
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
    var modifiers: UInt  // We will store raw value of NSEvent.ModifierFlags
    var keyCode: UInt16
}

struct Preferences: Codable {
    var idleTimeoutMinutes: Int
    var showLogoInMenuBar: Bool
    var developerDiagnosticsEnabled: Bool
    var workspaceSwitchModifier: WorkspaceSwitchModifier
    /// Padding in points that the command-palette layout commands leave
    /// around each tiled window (including between adjacent tiles). Defaults
    /// to 10 for a soft "island" look with clear breathing room. Users can
    /// push this up to 32 via the Settings slider, or down to 0 for a flush
    /// layout.
    var windowGap: Int

    init(
        idleTimeoutMinutes: Int,
        showLogoInMenuBar: Bool,
        developerDiagnosticsEnabled: Bool,
        workspaceSwitchModifier: WorkspaceSwitchModifier,
        windowGap: Int = 10
    ) {
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.showLogoInMenuBar = showLogoInMenuBar
        self.developerDiagnosticsEnabled = developerDiagnosticsEnabled
        self.workspaceSwitchModifier = workspaceSwitchModifier
        self.windowGap = windowGap
    }

    enum CodingKeys: String, CodingKey {
        case idleTimeoutMinutes
        case showLogoInMenuBar
        case developerDiagnosticsEnabled
        case workspaceSwitchModifier
        case windowGap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idleTimeoutMinutes = try container.decode(Int.self, forKey: .idleTimeoutMinutes)
        showLogoInMenuBar =
            try container.decodeIfPresent(Bool.self, forKey: .showLogoInMenuBar)
            ?? false
        developerDiagnosticsEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .developerDiagnosticsEnabled)
            ?? false
        workspaceSwitchModifier =
            try container.decodeIfPresent(
                WorkspaceSwitchModifier.self,
                forKey: .workspaceSwitchModifier
            )
            ?? .control
        windowGap =
            try container.decodeIfPresent(Int.self, forKey: .windowGap)
            ?? 10
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idleTimeoutMinutes, forKey: .idleTimeoutMinutes)
        try container.encode(showLogoInMenuBar, forKey: .showLogoInMenuBar)
        try container.encode(developerDiagnosticsEnabled, forKey: .developerDiagnosticsEnabled)
        try container.encode(workspaceSwitchModifier, forKey: .workspaceSwitchModifier)
        try container.encode(windowGap, forKey: .windowGap)
    }
}

enum WorkspaceSwitchModifier: String, Codable {
    case control
    case option
    case command
}

struct AppState: Codable {
    var activeWorkspaceId: UUID?
}
