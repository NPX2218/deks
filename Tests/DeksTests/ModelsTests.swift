import XCTest

@testable import Deks

final class ModelsTests: XCTestCase {

    // MARK: - Workspace

    func testWorkspaceRoundTripPreservesAllFields() throws {
        let ws = Workspace(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Focus",
            color: .mint,
            hotkey: HotkeyCombo(modifiers: 262_144, keyCode: 18),
            assignedWindows: [
                WindowRef(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    bundleID: "com.example.editor",
                    windowTitle: "main.swift",
                    matchRule: .exactTitle("main.swift"),
                    isPinned: true
                )
            ],
            idleOptimization: true,
            lastActiveAt: Date(timeIntervalSinceReferenceDate: 5000)
        )

        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        XCTAssertEqual(decoded.id, ws.id)
        XCTAssertEqual(decoded.name, ws.name)
        XCTAssertEqual(decoded.color, ws.color)
        XCTAssertEqual(decoded.hotkey, ws.hotkey)
        XCTAssertEqual(decoded.assignedWindows.count, 1)
        XCTAssertEqual(decoded.assignedWindows[0].id, ws.assignedWindows[0].id)
        XCTAssertEqual(decoded.assignedWindows[0].bundleID, "com.example.editor")
        XCTAssertTrue(decoded.assignedWindows[0].isPinned)
        XCTAssertTrue(decoded.idleOptimization)
        XCTAssertEqual(
            decoded.lastActiveAt.timeIntervalSinceReferenceDate,
            5000,
            accuracy: 0.001
        )
    }

    func testWorkspaceWithNilHotkeyRoundTrips() throws {
        let ws = Workspace(
            id: UUID(),
            name: "Untitled",
            color: .coral,
            hotkey: nil,
            assignedWindows: [],
            idleOptimization: false,
            lastActiveAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        XCTAssertNil(decoded.hotkey)
        XCTAssertTrue(decoded.assignedWindows.isEmpty)
        XCTAssertEqual(decoded.color, .coral)
    }

    // MARK: - WorkspaceColor

    func testWorkspaceColorAllCasesRoundTrip() throws {
        let cases: [WorkspaceColor] = [
            .green, .purple, .coral, .blue, .amber, .pink, .red, .mint,
        ]
        for color in cases {
            let data = try JSONEncoder().encode(color)
            let decoded = try JSONDecoder().decode(WorkspaceColor.self, from: data)
            XCTAssertEqual(decoded, color)
        }
    }

    // MARK: - WindowMatchRule

    func testWindowMatchRuleExactTitleRoundTrip() throws {
        try assertMatchRuleRoundTrip(.exactTitle("Terminal — bash"))
    }

    func testWindowMatchRuleTitleContainsRoundTrip() throws {
        try assertMatchRuleRoundTrip(.titleContains("Slack"))
    }

    func testWindowMatchRuleAppOnlyRoundTrip() throws {
        try assertMatchRuleRoundTrip(.appOnly("com.apple.Safari"))
    }

    func testWindowMatchRuleWindowIndexRoundTrip() throws {
        try assertMatchRuleRoundTrip(.windowIndex("com.brave.Browser", 2))
    }

    func testWindowMatchRuleWindowNumberRoundTrip() throws {
        try assertMatchRuleRoundTrip(.windowNumber("com.spotify.client", 12345))
    }

    private func assertMatchRuleRoundTrip(_ rule: WindowMatchRule) throws {
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(WindowMatchRule.self, from: data)
        switch (rule, decoded) {
        case let (.exactTitle(a), .exactTitle(b)):
            XCTAssertEqual(a, b)
        case let (.titleContains(a), .titleContains(b)):
            XCTAssertEqual(a, b)
        case let (.appOnly(a), .appOnly(b)):
            XCTAssertEqual(a, b)
        case let (.windowIndex(aBundle, aIndex), .windowIndex(bBundle, bIndex)):
            XCTAssertEqual(aBundle, bBundle)
            XCTAssertEqual(aIndex, bIndex)
        case let (.windowNumber(aBundle, aNumber), .windowNumber(bBundle, bNumber)):
            XCTAssertEqual(aBundle, bBundle)
            XCTAssertEqual(aNumber, bNumber)
        default:
            XCTFail("Match rule case mismatch: \(rule) vs \(decoded)")
        }
    }

    // MARK: - HotkeyCombo

    func testHotkeyComboEquality() {
        let a = HotkeyCombo(modifiers: 1024, keyCode: 18)
        let b = HotkeyCombo(modifiers: 1024, keyCode: 18)
        let c = HotkeyCombo(modifiers: 1024, keyCode: 19)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testHotkeyComboUsableAsDictionaryKey() {
        var map: [HotkeyCombo: String] = [:]
        let control1 = HotkeyCombo(modifiers: 262_144, keyCode: 18)
        let control2 = HotkeyCombo(modifiers: 262_144, keyCode: 19)
        map[control1] = "workspace-1"
        map[control2] = "workspace-2"
        XCTAssertEqual(map[control1], "workspace-1")
        XCTAssertEqual(map[control2], "workspace-2")
        XCTAssertEqual(map.count, 2)
    }

    func testHotkeyComboRoundTrip() throws {
        let combo = HotkeyCombo(modifiers: 524_288, keyCode: 48)
        let data = try JSONEncoder().encode(combo)
        let decoded = try JSONDecoder().decode(HotkeyCombo.self, from: data)
        XCTAssertEqual(decoded, combo)
    }

    // MARK: - AppState

    func testAppStateRoundTripWithActiveId() throws {
        let state = AppState(
            activeWorkspaceId: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded.activeWorkspaceId, state.activeWorkspaceId)
    }

    func testAppStateRoundTripWithNilActiveId() throws {
        let state = AppState(activeWorkspaceId: nil)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertNil(decoded.activeWorkspaceId)
    }

    // MARK: - Preferences

    func testPreferencesRoundTripPreservesAllFields() throws {
        let prefs = Preferences(
            idleTimeoutMinutes: 12,
            showLogoInMenuBar: true,
            developerDiagnosticsEnabled: true,
            workspaceSwitchModifier: .option
        )
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(decoded.idleTimeoutMinutes, 12)
        XCTAssertTrue(decoded.showLogoInMenuBar)
        XCTAssertTrue(decoded.developerDiagnosticsEnabled)
        XCTAssertEqual(decoded.workspaceSwitchModifier, .option)
    }

    func testPreferencesFallsBackToControlModifierWhenMissing() throws {
        // A legacy payload without the workspaceSwitchModifier key should
        // decode with the default `.control` modifier.
        let legacyJSON = """
            {
              "idleTimeoutMinutes": 3,
              "showLogoInMenuBar": true,
              "developerDiagnosticsEnabled": false
            }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Preferences.self, from: legacyJSON)
        XCTAssertEqual(decoded.workspaceSwitchModifier, .control)
        XCTAssertEqual(decoded.idleTimeoutMinutes, 3)
    }

    // MARK: - WorkspaceSwitchModifier

    func testWorkspaceSwitchModifierAllCasesRoundTrip() throws {
        for modifier in [WorkspaceSwitchModifier.control, .option, .command] {
            let data = try JSONEncoder().encode(modifier)
            let decoded = try JSONDecoder().decode(WorkspaceSwitchModifier.self, from: data)
            XCTAssertEqual(decoded, modifier)
        }
    }

    func testWorkspaceSwitchModifierRawValuesAreStable() {
        // These raw values are persisted to disk — changing them would break
        // every existing install. Lock them in place.
        XCTAssertEqual(WorkspaceSwitchModifier.control.rawValue, "control")
        XCTAssertEqual(WorkspaceSwitchModifier.option.rawValue, "option")
        XCTAssertEqual(WorkspaceSwitchModifier.command.rawValue, "command")
    }

    func testWorkspaceColorRawValuesAreStable() {
        XCTAssertEqual(WorkspaceColor.green.rawValue, "green")
        XCTAssertEqual(WorkspaceColor.purple.rawValue, "purple")
        XCTAssertEqual(WorkspaceColor.coral.rawValue, "coral")
        XCTAssertEqual(WorkspaceColor.blue.rawValue, "blue")
        XCTAssertEqual(WorkspaceColor.amber.rawValue, "amber")
        XCTAssertEqual(WorkspaceColor.pink.rawValue, "pink")
        XCTAssertEqual(WorkspaceColor.red.rawValue, "red")
        XCTAssertEqual(WorkspaceColor.mint.rawValue, "mint")
    }

    // MARK: - Forward/backward compatibility

    func testPreferencesIgnoresUnknownFields() throws {
        // A newer version's JSON containing fields this version doesn't know
        // about must still decode successfully (forward compat).
        let forwardJSON = """
            {
              "idleTimeoutMinutes": 10,
              "showLogoInMenuBar": false,
              "developerDiagnosticsEnabled": false,
              "workspaceSwitchModifier": "control",
              "futurePieOnChartsEnabled": true,
              "mysteryTuningKnob": 42
            }
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Preferences.self, from: forwardJSON)
        XCTAssertEqual(decoded.idleTimeoutMinutes, 10)
        XCTAssertEqual(decoded.workspaceSwitchModifier, .control)
    }

    func testPreferencesEncodesAllKnownKeys() throws {
        let prefs = Preferences(
            idleTimeoutMinutes: 5,
            showLogoInMenuBar: false,
            developerDiagnosticsEnabled: false,
            workspaceSwitchModifier: .command
        )
        let data = try JSONEncoder().encode(prefs)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected JSON object")
            return
        }
        XCTAssertNotNil(json["idleTimeoutMinutes"])
        XCTAssertNotNil(json["showLogoInMenuBar"])
        XCTAssertNotNil(json["developerDiagnosticsEnabled"])
        XCTAssertNotNil(json["workspaceSwitchModifier"])
        // No phantom "defaultNewWindowBehavior" survivor from the removed
        // preference, which would corrupt downgraded installs.
        XCTAssertNil(json["defaultNewWindowBehavior"])
    }

    // MARK: - WindowRef with multiple match rules

    func testWindowRefPinnedRoundTripForAllRuleVariants() throws {
        let variants: [WindowMatchRule] = [
            .exactTitle("Editor"),
            .titleContains("Slack"),
            .appOnly("com.example.app"),
            .windowIndex("com.example.app", 0),
            .windowNumber("com.example.app", 999),
        ]
        for rule in variants {
            let ref = WindowRef(
                id: UUID(),
                bundleID: "com.example.app",
                windowTitle: "Test",
                matchRule: rule,
                isPinned: true
            )
            let data = try JSONEncoder().encode(ref)
            let decoded = try JSONDecoder().decode(WindowRef.self, from: data)
            XCTAssertTrue(decoded.isPinned, "pinned flag lost for rule \(rule)")
            XCTAssertEqual(decoded.id, ref.id)
        }
    }

    // MARK: - HotkeyCombo edge cases

    func testHotkeyComboDifferentKeyCodesProduceDifferentHashes() {
        var seen = Set<HotkeyCombo>()
        for keyCode: UInt16 in 0..<50 {
            seen.insert(HotkeyCombo(modifiers: 0, keyCode: keyCode))
        }
        XCTAssertEqual(seen.count, 50)
    }

    func testHotkeyComboDifferentModifiersProduceDifferentHashes() {
        var seen = Set<HotkeyCombo>()
        for modifiers: UInt in [0, 1024, 262_144, 524_288, 1_048_576] {
            seen.insert(HotkeyCombo(modifiers: modifiers, keyCode: 48))
        }
        XCTAssertEqual(seen.count, 5)
    }

    func testHotkeyComboZeroIsValidAndDistinct() {
        let zero = HotkeyCombo(modifiers: 0, keyCode: 0)
        let maxKey = HotkeyCombo(modifiers: 0, keyCode: UInt16.max)
        XCTAssertNotEqual(zero, maxKey)
        XCTAssertEqual(zero, HotkeyCombo(modifiers: 0, keyCode: 0))
    }

    // MARK: - Workspace batch operations

    func testWorkspaceEncodesMultipleWindowsInOrder() throws {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let ws = Workspace(
            id: UUID(),
            name: "Batch",
            color: .red,
            hotkey: nil,
            assignedWindows: [
                WindowRef(
                    id: id1,
                    bundleID: "a",
                    windowTitle: "One",
                    matchRule: .exactTitle("One")
                ),
                WindowRef(
                    id: id2,
                    bundleID: "b",
                    windowTitle: "Two",
                    matchRule: .appOnly("b")
                ),
                WindowRef(
                    id: id3,
                    bundleID: "c",
                    windowTitle: "Three",
                    matchRule: .windowNumber("c", 100)
                ),
            ],
            idleOptimization: false,
            lastActiveAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        XCTAssertEqual(decoded.assignedWindows.map(\.id), [id1, id2, id3])
        XCTAssertEqual(decoded.assignedWindows[0].bundleID, "a")
        XCTAssertEqual(decoded.assignedWindows[2].bundleID, "c")
    }

    func testWorkspaceWithEveryColorRoundTrips() throws {
        for color: WorkspaceColor in [.green, .purple, .coral, .blue, .amber, .pink, .red, .mint] {
            let ws = Workspace(
                id: UUID(),
                name: "Color \(color.rawValue)",
                color: color,
                hotkey: nil,
                assignedWindows: [],
                idleOptimization: false,
                lastActiveAt: Date(timeIntervalSinceReferenceDate: 0)
            )
            let data = try JSONEncoder().encode(ws)
            let decoded = try JSONDecoder().decode(Workspace.self, from: data)
            XCTAssertEqual(decoded.color, color)
        }
    }
}
