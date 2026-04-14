import XCTest

@testable import Deks

final class WorkspaceMutationsTests: XCTestCase {

    // MARK: - Test fixtures

    private func makeWindowRef(
        id: UUID = UUID(),
        bundleID: String = "com.example.app",
        title: String = "Window",
        pinned: Bool = false
    ) -> Deks.WindowRef {
        Deks.WindowRef(
            id: id,
            bundleID: bundleID,
            windowTitle: title,
            matchRule: .exactTitle(title),
            isPinned: pinned
        )
    }

    private func makeWorkspace(
        id: UUID = UUID(),
        name: String = "Test",
        color: WorkspaceColor = .blue,
        windows: [Deks.WindowRef] = []
    ) -> Workspace {
        Workspace(
            id: id,
            name: name,
            color: color,
            hotkey: nil,
            assignedWindows: windows,
            idleOptimization: false,
            lastActiveAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }

    // MARK: - moveWindowToFront

    func testMoveWindowToEmptyTargetInsertsAtFront() {
        let windowID = UUID()
        let fallback = makeWindowRef(id: windowID)
        let workspaces = [
            makeWorkspace(name: "A"),
            makeWorkspace(name: "B"),
        ]

        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: 1,
            fallbackRef: fallback
        )

        XCTAssertEqual(result[0].assignedWindows.count, 0)
        XCTAssertEqual(result[1].assignedWindows.count, 1)
        XCTAssertEqual(result[1].assignedWindows[0].id, windowID)
    }

    func testMoveWindowGoesToFrontNotBack() {
        let windowID = UUID()
        let existingID = UUID()
        let fallback = makeWindowRef(id: windowID)

        let workspaces = [
            makeWorkspace(windows: [makeWindowRef(id: existingID, title: "Existing")])
        ]

        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: 0,
            fallbackRef: fallback
        )

        XCTAssertEqual(result[0].assignedWindows.count, 2)
        XCTAssertEqual(result[0].assignedWindows[0].id, windowID)
        XCTAssertEqual(result[0].assignedWindows[1].id, existingID)
    }

    func testMoveWindowRemovesFromSourceWorkspace() {
        let windowID = UUID()
        let ref = makeWindowRef(id: windowID, title: "Moving")
        let fallback = makeWindowRef(id: windowID)

        let workspaces = [
            makeWorkspace(name: "Source", windows: [ref]),
            makeWorkspace(name: "Target"),
        ]

        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: 1,
            fallbackRef: fallback
        )

        XCTAssertTrue(result[0].assignedWindows.isEmpty)
        XCTAssertEqual(result[1].assignedWindows.count, 1)
        XCTAssertEqual(result[1].assignedWindows[0].id, windowID)
    }

    func testMoveWindowPreservesPinnedStateFromExistingRef() {
        let windowID = UUID()
        let pinnedRef = makeWindowRef(id: windowID, title: "Pinned One", pinned: true)
        let fallback = makeWindowRef(id: windowID, pinned: false)

        let workspaces = [
            makeWorkspace(name: "A", windows: [pinnedRef]),
            makeWorkspace(name: "B"),
        ]

        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: 1,
            fallbackRef: fallback
        )

        XCTAssertTrue(result[1].assignedWindows[0].isPinned)
        XCTAssertEqual(result[1].assignedWindows[0].windowTitle, "Pinned One")
    }

    func testMoveWindowAlreadyInTargetGoesToFront() {
        let windowID = UUID()
        let otherID = UUID()
        let ref = makeWindowRef(id: windowID, title: "Moving")
        let otherRef = makeWindowRef(id: otherID, title: "Other")
        let fallback = makeWindowRef(id: windowID)

        // windowID is currently at position 1
        let workspaces = [
            makeWorkspace(windows: [otherRef, ref])
        ]

        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: 0,
            fallbackRef: fallback
        )

        XCTAssertEqual(result[0].assignedWindows.count, 2)
        XCTAssertEqual(result[0].assignedWindows[0].id, windowID)
        XCTAssertEqual(result[0].assignedWindows[1].id, otherID)
    }

    func testMoveWindowUsesFallbackWhenNotAlreadyOwned() {
        let windowID = UUID()
        let fallback = makeWindowRef(
            id: windowID,
            bundleID: "com.brand.new",
            title: "Fresh"
        )

        let workspaces = [makeWorkspace()]
        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: 0,
            fallbackRef: fallback
        )

        XCTAssertEqual(result[0].assignedWindows[0].bundleID, "com.brand.new")
        XCTAssertEqual(result[0].assignedWindows[0].windowTitle, "Fresh")
    }

    func testMoveWindowNegativeIndexIsNoOp() {
        let windowID = UUID()
        let fallback = makeWindowRef(id: windowID)
        let workspaces = [makeWorkspace(windows: [makeWindowRef()])]

        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: -1,
            fallbackRef: fallback
        )

        XCTAssertEqual(result.count, workspaces.count)
        XCTAssertEqual(result[0].assignedWindows.count, 1)
        XCTAssertFalse(result[0].assignedWindows.contains(where: { $0.id == windowID }))
    }

    func testMoveWindowOutOfBoundsIndexIsNoOp() {
        let windowID = UUID()
        let fallback = makeWindowRef(id: windowID)
        let workspaces = [makeWorkspace()]

        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: 5,
            fallbackRef: fallback
        )

        XCTAssertEqual(result[0].assignedWindows.count, 0)
    }

    func testMoveWindowNeverCreatesDuplicate() {
        let windowID = UUID()
        let ref = makeWindowRef(id: windowID)
        let fallback = makeWindowRef(id: windowID)

        // Window appears in workspace 0 twice (synthetic bad state).
        let workspaces = [
            makeWorkspace(windows: [ref, ref]),
            makeWorkspace(),
        ]

        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: 1,
            fallbackRef: fallback
        )

        XCTAssertEqual(result[0].assignedWindows.count, 0)
        XCTAssertEqual(result[1].assignedWindows.count, 1)
    }

    func testMoveWindowBetweenThreeWorkspacesLeavesOthersUntouched() {
        let windowID = UUID()
        let otherID = UUID()
        let ref = makeWindowRef(id: windowID, title: "Target window")
        let other = makeWindowRef(id: otherID, title: "Untouched")
        let fallback = makeWindowRef(id: windowID)

        let workspaces = [
            makeWorkspace(name: "A", windows: [ref]),
            makeWorkspace(name: "B", windows: [other]),
            makeWorkspace(name: "C"),
        ]

        let result = WorkspaceMutations.moveWindowToFront(
            of: workspaces,
            windowID: windowID,
            targetIndex: 2,
            fallbackRef: fallback
        )

        XCTAssertTrue(result[0].assignedWindows.isEmpty)
        XCTAssertEqual(result[1].assignedWindows.count, 1)
        XCTAssertEqual(result[1].assignedWindows[0].id, otherID)
        XCTAssertEqual(result[2].assignedWindows.count, 1)
        XCTAssertEqual(result[2].assignedWindows[0].id, windowID)
    }

    // MARK: - owningWorkspaceIndex

    func testOwningWorkspaceIndexFindsFirstMatch() {
        let windowID = UUID()
        let ref = makeWindowRef(id: windowID)
        let workspaces = [
            makeWorkspace(name: "A"),
            makeWorkspace(name: "B", windows: [ref]),
            makeWorkspace(name: "C"),
        ]

        XCTAssertEqual(
            WorkspaceMutations.owningWorkspaceIndex(of: windowID, in: workspaces),
            1
        )
    }

    func testOwningWorkspaceIndexReturnsNilWhenMissing() {
        let workspaces = [makeWorkspace(), makeWorkspace()]
        XCTAssertNil(
            WorkspaceMutations.owningWorkspaceIndex(of: UUID(), in: workspaces)
        )
    }

    func testOwningWorkspaceIndexEmptyListReturnsNil() {
        XCTAssertNil(
            WorkspaceMutations.owningWorkspaceIndex(of: UUID(), in: [])
        )
    }

    // MARK: - isWindowAssignedToActive

    func testIsWindowAssignedToActiveTrueWhenInActive() {
        let windowID = UUID()
        let activeId = UUID()
        let workspaces = [
            makeWorkspace(id: activeId, windows: [makeWindowRef(id: windowID)])
        ]

        XCTAssertTrue(
            WorkspaceMutations.isWindowAssignedToActive(
                windowID: windowID,
                activeId: activeId,
                workspaces: workspaces
            )
        )
    }

    func testIsWindowAssignedToActiveFalseWhenInOtherWorkspace() {
        let windowID = UUID()
        let activeId = UUID()
        let otherId = UUID()
        let workspaces = [
            makeWorkspace(id: activeId),
            makeWorkspace(id: otherId, windows: [makeWindowRef(id: windowID)]),
        ]

        XCTAssertFalse(
            WorkspaceMutations.isWindowAssignedToActive(
                windowID: windowID,
                activeId: activeId,
                workspaces: workspaces
            )
        )
    }

    func testIsWindowAssignedToActiveFalseWhenActiveIdNil() {
        let windowID = UUID()
        let workspaces = [makeWorkspace(windows: [makeWindowRef(id: windowID)])]
        XCTAssertFalse(
            WorkspaceMutations.isWindowAssignedToActive(
                windowID: windowID,
                activeId: nil,
                workspaces: workspaces
            )
        )
    }

    func testIsWindowAssignedToActiveFalseWhenWorkspaceMissing() {
        let windowID = UUID()
        let staleId = UUID()
        let workspaces = [makeWorkspace(id: UUID())]
        XCTAssertFalse(
            WorkspaceMutations.isWindowAssignedToActive(
                windowID: windowID,
                activeId: staleId,
                workspaces: workspaces
            )
        )
    }

    // MARK: - removeWindow

    func testRemoveWindowDropsAllOccurrences() {
        let windowID = UUID()
        let ref = makeWindowRef(id: windowID)
        let otherRef = makeWindowRef()

        let workspaces = [
            makeWorkspace(name: "A", windows: [ref, otherRef]),
            makeWorkspace(name: "B", windows: [ref]),
            makeWorkspace(name: "C"),
        ]

        let result = WorkspaceMutations.removeWindow(windowID, from: workspaces)

        XCTAssertEqual(result[0].assignedWindows.count, 1)
        XCTAssertEqual(result[0].assignedWindows[0].id, otherRef.id)
        XCTAssertTrue(result[1].assignedWindows.isEmpty)
        XCTAssertTrue(result[2].assignedWindows.isEmpty)
    }

    func testRemoveWindowNotPresentLeavesWorkspacesUnchanged() {
        let windowID = UUID()
        let otherRef = makeWindowRef()
        let workspaces = [makeWorkspace(windows: [otherRef])]

        let result = WorkspaceMutations.removeWindow(windowID, from: workspaces)

        XCTAssertEqual(result[0].assignedWindows.count, 1)
        XCTAssertEqual(result[0].assignedWindows[0].id, otherRef.id)
    }

    func testRemoveWindowFromEmptyWorkspaces() {
        let result = WorkspaceMutations.removeWindow(UUID(), from: [])
        XCTAssertTrue(result.isEmpty)
    }
}
