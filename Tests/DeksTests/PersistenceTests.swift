import XCTest

@testable import Deks

final class PersistenceTests: XCTestCase {

    // MARK: - defaultPreferences

    func testDefaultPreferencesHaveExpectedValues() {
        let defaults = Persistence.defaultPreferences
        XCTAssertEqual(defaults.idleTimeoutMinutes, 5)
        XCTAssertFalse(defaults.showLogoInMenuBar)
        XCTAssertFalse(defaults.developerDiagnosticsEnabled)
        XCTAssertEqual(defaults.workspaceSwitchModifier, .control)
    }

    func testDefaultPreferencesIdleTimeoutIsPositive() {
        XCTAssertGreaterThan(Persistence.defaultPreferences.idleTimeoutMinutes, 0)
    }

    // MARK: - File URL structure

    func testAppSupportDirIsInsideDeksFolder() {
        let dir = Persistence.appSupportDir
        XCTAssertTrue(
            dir.path.contains("/Deks"),
            "appSupportDir should live under a 'Deks' folder, got \(dir.path)"
        )
    }

    func testWorkspacesFileUrlEndsWithWorkspacesJson() {
        let url = Persistence.workspacesFileUrl()
        XCTAssertEqual(url.lastPathComponent, "workspaces.json")
    }

    func testPreferencesFileUrlEndsWithPreferencesJson() {
        let url = Persistence.preferencesFileUrl()
        XCTAssertEqual(url.lastPathComponent, "preferences.json")
    }

    func testAppStateFileUrlEndsWithAppStateJson() {
        let url = Persistence.appStateFileUrl()
        XCTAssertEqual(url.lastPathComponent, "app-state.json")
    }

    func testAllPersistenceFilesLiveUnderAppSupportDir() {
        let base = Persistence.appSupportDir.path
        XCTAssertTrue(Persistence.workspacesFileUrl().path.hasPrefix(base))
        XCTAssertTrue(Persistence.preferencesFileUrl().path.hasPrefix(base))
        XCTAssertTrue(Persistence.appStateFileUrl().path.hasPrefix(base))
    }

    // MARK: - Defaults round-trip

    func testDefaultPreferencesEncodeDecodeRoundTrip() throws {
        let defaults = Persistence.defaultPreferences
        let data = try JSONEncoder().encode(defaults)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(decoded.idleTimeoutMinutes, defaults.idleTimeoutMinutes)
        XCTAssertEqual(decoded.showLogoInMenuBar, defaults.showLogoInMenuBar)
        XCTAssertEqual(
            decoded.developerDiagnosticsEnabled,
            defaults.developerDiagnosticsEnabled
        )
        XCTAssertEqual(decoded.workspaceSwitchModifier, defaults.workspaceSwitchModifier)
    }
}
