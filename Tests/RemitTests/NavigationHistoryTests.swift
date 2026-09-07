import XCTest
@testable import Remit

/// A trackpad swipe cannot be synthesised in a test, so the gesture itself is only verifiable by
/// hand. The history it drives is not, and that is where the behaviour actually lives -- these pin
/// down the browser semantics the swipe depends on.
@MainActor
final class NavigationHistoryTests: XCTestCase {

    func testStartsWithNowhereToGo() {
        let sut = NavigationHistory(start: .today)

        XCTAssertFalse(sut.canGoBack)
        XCTAssertFalse(sut.canGoForward)
        XCTAssertNil(sut.goBack())
        XCTAssertNil(sut.goForward())
    }

    func testBackReturnsThroughTheTrailInOrder() {
        let sut = NavigationHistory(start: .today)
        sut.visit(.upcoming)
        sut.visit(.project("p1"))

        XCTAssertEqual(sut.goBack(), .upcoming)
        XCTAssertEqual(sut.goBack(), .today)
        XCTAssertNil(sut.goBack(), "the trail ends rather than wrapping")
    }

    func testForwardRetracesWhatBackUndid() {
        let sut = NavigationHistory(start: .today)
        sut.visit(.upcoming)
        sut.visit(.inbox)
        sut.goBack()
        sut.goBack()

        XCTAssertEqual(sut.goForward(), .upcoming)
        XCTAssertEqual(sut.goForward(), .inbox)
        XCTAssertNil(sut.goForward())
    }

    /// The rule that makes this history rather than a two-view toggle: navigating somewhere new
    /// after going back abandons the forward trail.
    func testVisitingAfterGoingBackDiscardsForward() {
        let sut = NavigationHistory(start: .today)
        sut.visit(.upcoming)
        sut.goBack()
        XCTAssertTrue(sut.canGoForward)

        sut.visit(.project("p9"))

        XCTAssertFalse(sut.canGoForward)
        XCTAssertEqual(sut.goBack(), .today, "back still walks the real trail")
    }

    /// Clicking the view you are already on is not a navigation. Recording it would make every
    /// redundant click a step the user has to swipe back through.
    func testReselectingTheCurrentViewIsNotRecorded() {
        let sut = NavigationHistory(start: .today)

        sut.visit(.today)
        sut.visit(.today)

        XCTAssertFalse(sut.canGoBack)
    }

    func testNilSelectionIsIgnored() {
        let sut = NavigationHistory(start: .today)

        sut.visit(nil)

        XCTAssertFalse(sut.canGoBack)
        XCTAssertEqual(sut.current, .today)
    }

    func testBackAndForwardRoundTripLeavesHistoryUnchanged() {
        let sut = NavigationHistory(start: .today)
        sut.visit(.upcoming)
        sut.visit(.inbox)

        sut.goBack()
        sut.goForward()

        XCTAssertEqual(sut.current, .inbox)
        XCTAssertFalse(sut.canGoForward)
        XCTAssertEqual(sut.goBack(), .upcoming)
    }

    /// Unbounded growth over a long session is the only way this leaks, so the cap is asserted.
    func testHistoryIsBounded() {
        let sut = NavigationHistory(start: .today)
        for i in 0..<120 { sut.visit(.project("p\(i)")) }

        var steps = 0
        while sut.goBack() != nil { steps += 1 }

        XCTAssertLessThanOrEqual(steps, 50)
        XCTAssertGreaterThan(steps, 40, "the cap should not be trimming far more than it must")
    }
}
