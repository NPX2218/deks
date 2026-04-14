import XCTest

@testable import Deks

final class QuickSwitcherCycleTests: XCTestCase {
    func testForwardFromMiddleAdvances() {
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 1, count: 3, forward: true),
            2
        )
    }

    func testForwardFromLastWrapsToFirst() {
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 2, count: 3, forward: true),
            0
        )
    }

    func testBackwardFromFirstWrapsToLast() {
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 0, count: 3, forward: false),
            2
        )
    }

    func testBackwardFromMiddleGoesBack() {
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 2, count: 3, forward: false),
            1
        )
    }

    func testSingleElementStaysAtZeroForward() {
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 0, count: 1, forward: true),
            0
        )
    }

    func testSingleElementStaysAtZeroBackward() {
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 0, count: 1, forward: false),
            0
        )
    }

    func testEmptyListReturnsZero() {
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 0, count: 0, forward: true),
            0
        )
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 5, count: 0, forward: false),
            0
        )
    }

    func testNegativeCurrentIsTreatedAsUnselected() {
        // NSTableView returns -1 when nothing is selected. From that state,
        // forward should land on index 1 (skipping past 0) to simulate
        // "one step past the logical active row".
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: -1, count: 3, forward: true),
            1
        )
        // Backward from unselected wraps to the end.
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: -1, count: 3, forward: false),
            2
        )
    }

    func testMultipleForwardStepsCycleCorrectly() {
        var idx = 0
        for _ in 0..<7 {
            idx = QuickSwitcherCycle.nextIndex(current: idx, count: 3, forward: true)
        }
        // 0 → 1 → 2 → 0 → 1 → 2 → 0 → 1  (7 steps)
        XCTAssertEqual(idx, 1)
    }

    func testMultipleBackwardStepsCycleCorrectly() {
        var idx = 0
        for _ in 0..<4 {
            idx = QuickSwitcherCycle.nextIndex(current: idx, count: 5, forward: false)
        }
        // 0 → 4 → 3 → 2 → 1  (4 steps)
        XCTAssertEqual(idx, 1)
    }

    // MARK: - Two-workspace flip-flop (most common case)

    func testTwoWorkspacesFlipFlopForward() {
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 0, count: 2, forward: true),
            1
        )
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 1, count: 2, forward: true),
            0
        )
    }

    func testTwoWorkspacesFlipFlopBackward() {
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 0, count: 2, forward: false),
            1
        )
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 1, count: 2, forward: false),
            0
        )
    }

    // MARK: - Nine workspaces (max default hotkey count)

    func testNineWorkspacesForwardFullCycleReturnsToStart() {
        var idx = 0
        for _ in 0..<9 {
            idx = QuickSwitcherCycle.nextIndex(current: idx, count: 9, forward: true)
        }
        XCTAssertEqual(idx, 0)
    }

    func testNineWorkspacesBackwardFullCycleReturnsToStart() {
        var idx = 0
        for _ in 0..<9 {
            idx = QuickSwitcherCycle.nextIndex(current: idx, count: 9, forward: false)
        }
        XCTAssertEqual(idx, 0)
    }

    // MARK: - Very large lists

    func testVeryLargeListCyclesCorrectly() {
        let count = 100
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 99, count: count, forward: true),
            0
        )
        XCTAssertEqual(
            QuickSwitcherCycle.nextIndex(current: 0, count: count, forward: false),
            99
        )
    }

    // MARK: - Out-of-range current

    func testCurrentAboveCountStillProducesValidIndex() {
        // This shouldn't happen in practice (NSTableView's selectedRow stays
        // in range) but the helper must never crash or return an invalid
        // index under unexpected inputs.
        let result = QuickSwitcherCycle.nextIndex(current: 1000, count: 3, forward: true)
        XCTAssertTrue((0..<3).contains(result))
    }

    func testCurrentAboveCountBackwardStillValid() {
        let result = QuickSwitcherCycle.nextIndex(current: 1000, count: 3, forward: false)
        XCTAssertTrue((0..<3).contains(result))
    }

    // MARK: - Alternating directions

    func testAlternatingForwardBackwardReturnsToOrigin() {
        var idx = 2
        idx = QuickSwitcherCycle.nextIndex(current: idx, count: 5, forward: true)
        idx = QuickSwitcherCycle.nextIndex(current: idx, count: 5, forward: false)
        XCTAssertEqual(idx, 2)
    }

    func testAlternatingBackwardForwardReturnsToOrigin() {
        var idx = 3
        idx = QuickSwitcherCycle.nextIndex(current: idx, count: 5, forward: false)
        idx = QuickSwitcherCycle.nextIndex(current: idx, count: 5, forward: true)
        XCTAssertEqual(idx, 3)
    }

    // MARK: - Determinism / property-style checks

    func testEveryPositionCanBeReachedByForwardCycling() {
        var seen = Set<Int>()
        var idx = 0
        for _ in 0..<10 {
            seen.insert(idx)
            idx = QuickSwitcherCycle.nextIndex(current: idx, count: 7, forward: true)
        }
        XCTAssertEqual(seen, Set(0..<7))
    }

    func testEveryPositionCanBeReachedByBackwardCycling() {
        var seen = Set<Int>()
        var idx = 0
        for _ in 0..<10 {
            seen.insert(idx)
            idx = QuickSwitcherCycle.nextIndex(current: idx, count: 7, forward: false)
        }
        XCTAssertEqual(seen, Set(0..<7))
    }

    func testResultAlwaysWithinBounds() {
        // Fuzz-ish check: sweep a wide range of inputs and ensure every
        // output is within [0, count).
        for count in 1...20 {
            for current in -5...25 {
                let forward = QuickSwitcherCycle.nextIndex(
                    current: current, count: count, forward: true
                )
                let backward = QuickSwitcherCycle.nextIndex(
                    current: current, count: count, forward: false
                )
                XCTAssertTrue((0..<count).contains(forward))
                XCTAssertTrue((0..<count).contains(backward))
            }
        }
    }
}
