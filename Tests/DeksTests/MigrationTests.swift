import XCTest

@testable import Deks

final class MigrationTests: XCTestCase {
    func testPreferencesDecodesLegacyPayloadWithoutLogoFlag() throws {
        let legacyJSON = """
            {
              "defaultNewWindowBehavior": "autoAssignToActive",
              "idleTimeoutMinutes": 7
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Preferences.self, from: legacyJSON)
        XCTAssertEqual(decoded.defaultNewWindowBehavior, .autoAssignToActive)
        XCTAssertEqual(decoded.idleTimeoutMinutes, 7)
        XCTAssertFalse(decoded.showLogoInMenuBar)
        XCTAssertEqual(decoded.workspaceSwitchModifier, .control)
    }

    func testWindowRefDecodesLegacyPayloadWithoutPinnedFlag() throws {
        let legacyJSON = """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "bundleID": "com.example.app",
              "windowTitle": "Main",
              "matchRule": {
                "exactTitle": {
                  "_0": "Main"
                }
              }
            }
            """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(WindowRef.self, from: legacyJSON)
        XCTAssertEqual(decoded.bundleID, "com.example.app")
        XCTAssertEqual(decoded.windowTitle, "Main")
        XCTAssertFalse(decoded.isPinned)
    }

    func testWindowRefRoundTripPreservesPinnedState() throws {
        let original = WindowRef(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            bundleID: "com.example.browser",
            windowTitle: "Docs",
            matchRule: .exactTitle("Docs"),
            isPinned: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WindowRef.self, from: data)
        XCTAssertTrue(decoded.isPinned)
        XCTAssertEqual(decoded.bundleID, original.bundleID)
        XCTAssertEqual(decoded.windowTitle, original.windowTitle)
    }
}
