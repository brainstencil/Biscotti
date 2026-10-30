import CoreGraphics
import Foundation
import Testing
@testable import TranscriptUI

private func bubbleItem(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> TranscriptItem {
    TranscriptItem(id: id, kind: .bubble(Bubble(side: .leading, startTime: start, endTime: end, settledText: id)))
}

private let items = [bubbleItem("a", 0, 5), bubbleItem("b", 5, 9), bubbleItem("c", 12, 15)]

private func view(_ times: ClosedRange<TimeInterval>?) -> VisibleSpan {
    VisibleSpan(times: times, height: 431, listTop: 540, listHeight: 431, insetTop: 0, insetBottom: 0)
}

/// Where a reveal's scroll landed: a lazy list that estimates the heights of
/// rows it has not made can land short of a far item or past it.
@Suite("Reveal landing check")
@MainActor
struct RevealLandingCheckTests {
    @Test("an item in view has landed; out of view, it is asked for again a bounded number of times")
    func landingOutcomes() {
        var check = RevealLandingCheck(itemID: "b", time: 6)
        #expect(check.landed(.inView) == .landed)

        check = RevealLandingCheck(itemID: "b", time: 6)
        #expect(check.landed(.notShown) == .retry(attempt: 1))
        #expect(check.landed(.below) == .retry(attempt: 2))
        #expect(check.landed(.above) == .retry(attempt: 3))
        #expect(check.landed(.notShown) == .gaveUp)
    }

    @Test("a reveal that lands away from its item asks for it again, then stops checking once it is in view")
    func revealLandingAwayAsksAgain() {
        let follower = FollowController(mode: .live)
        follower.reveal(time: 6, latest: items)
        #expect(follower.revealToCheck == "b")
        follower.consumeScrollRequest()

        follower.revealLanded(.notShown, in: view(150 ... 240))
        #expect(follower.scrollRequest?.itemID == "b")
        #expect(follower.scrollRequest?.anchor == .top)
        follower.consumeScrollRequest()

        follower.revealLanded(.inView, in: view(5 ... 20))
        #expect(follower.scrollRequest == nil)
        #expect(follower.revealToCheck == nil)
        #expect(!follower.isFollowing)
    }

    @Test("after the last attempt the reveal stays where it landed")
    func revealGivesUpAfterTheLastAttempt() {
        let follower = FollowController(mode: .never)
        follower.reveal(time: 6, latest: items)
        follower.consumeScrollRequest()
        for _ in 0 ..< RevealLandingCheck.attempts {
            follower.revealLanded(.below, in: view(0 ... 4))
            #expect(follower.scrollRequest?.itemID == "b")
            follower.consumeScrollRequest()
        }

        follower.revealLanded(.below, in: view(0 ... 4))

        #expect(follower.scrollRequest == nil)
        #expect(follower.revealToCheck == nil)
    }

    @Test("a check does not stack a request on one still waiting, and Return to live ends it")
    func checkLeavesPendingRequestsAndEndsWithReturnToLive() {
        let follower = FollowController(mode: .live)
        follower.reveal(time: 6, latest: items)
        let pending = follower.scrollRequest

        follower.revealLanded(.notShown, in: view(nil))
        #expect(follower.scrollRequest == pending)

        follower.returnToLive(latest: items)
        #expect(follower.revealToCheck == nil)
        follower.consumeScrollRequest()
        follower.revealLanded(.notShown, in: view(nil))
        #expect(follower.scrollRequest == nil)
    }

    @Test("a find match's scroll replaces the reveal: its landing is no longer checked")
    func findScrollEndsTheCheck() {
        let follower = FollowController(mode: .live)
        follower.reveal(time: 6, latest: items)
        follower.consumeScrollRequest()

        follower.scroll(to: "c", anchor: .center)
        #expect(follower.revealToCheck == nil)
        follower.consumeScrollRequest()

        follower.revealLanded(.notShown, in: view(12 ... 15))
        #expect(follower.scrollRequest == nil)
    }

    @Test("a check made while the scroll to the item still waits uses no attempt")
    func pendingScrollToTheItemUsesNoAttempt() {
        let follower = FollowController(mode: .never)
        follower.reveal(time: 6, latest: items)
        let pending = follower.scrollRequest
        for _ in 0 ..< RevealLandingCheck.attempts + 1 {
            follower.revealLanded(.notShown, in: view(nil))
        }
        #expect(follower.scrollRequest == pending)
        #expect(follower.revealToCheck == "b")
        follower.consumeScrollRequest()

        // Every attempt is still there once the scroll has been performed.
        for _ in 0 ..< RevealLandingCheck.attempts {
            follower.revealLanded(.below, in: view(0 ... 4))
            #expect(follower.scrollRequest?.itemID == "b")
            follower.consumeScrollRequest()
        }
        follower.revealLanded(.below, in: view(0 ... 4))
        #expect(follower.revealToCheck == nil)
    }

    @Test("rows behind the meeting page's band and card are below what the reader sees")
    func rowPlacementWithABottomInset() {
        let tracker = VisibleRowTracker()
        // A 700 pt list at the window's top whose lower 380 pt are under the chat card and the band.
        tracker.updateList(frame: CGRect(x: 0, y: 0, width: 600, height: 700))
        tracker.updateScroll(offsetY: 2000, insetTop: 0, insetBottom: 380, viewportHeight: 700)
        tracker.update(id: "visible", startTime: 60, frame: CGRect(x: 0, y: 200, width: 100, height: 50))
        tracker.update(id: "straddling", startTime: 70, frame: CGRect(x: 0, y: 300, width: 100, height: 50))
        tracker.update(id: "behindCard", startTime: 80, frame: CGRect(x: 0, y: 400, width: 100, height: 50))

        #expect(tracker.placement(of: "visible") == .inView)
        #expect(tracker.placement(of: "straddling") == .inView)
        #expect(tracker.placement(of: "behindCard") == .below)
        #expect(tracker.timesInView == 60 ... 70)
        #expect(tracker.visibleSpan.description == "60.0–70.0 s (view 700 pt, list at 0 pt in the window, 700 pt high, insets 0 top, 380 bottom)")
    }

    @Test("before the list reports its geometry, the log reads the view's height as unknown")
    func unknownHeightInTheLog() {
        let tracker = VisibleRowTracker()
        #expect(tracker.visibleSpan.description
            == "no rows (view unknown pt, list at unknown pt in the window, unknown pt high, insets 0 top, 0 bottom)")
        let span = VisibleSpan(times: 1 ... 2, height: .infinity, listTop: 539.6, listHeight: .nan, insetTop: .nan, insetBottom: 12.4)
        #expect(span.description == "1.0–2.0 s (view unknown pt, list at 540 pt in the window, unknown pt high, insets unknown top, 12 bottom)")
    }

    @Test("a row is in view, above or below what the reader sees, or not made")
    func rowPlacement() {
        let tracker = VisibleRowTracker()
        tracker.updateScroll(offsetY: 900, insetTop: 20, viewportHeight: 400)
        tracker.update(id: "above", startTime: 10, frame: CGRect(x: 0, y: -40, width: 100, height: 50))
        tracker.update(id: "underInset", startTime: 15, frame: CGRect(x: 0, y: -30, width: 100, height: 40))
        tracker.update(id: "top", startTime: 20, frame: CGRect(x: 0, y: 14, width: 100, height: 50))
        tracker.update(id: "bottom", startTime: 30, frame: CGRect(x: 0, y: 380, width: 100, height: 50))
        tracker.update(id: "below", startTime: 40, frame: CGRect(x: 0, y: 400, width: 100, height: 50))

        #expect(tracker.placement(of: "above") == .above)
        #expect(tracker.placement(of: "underInset") == .above)
        #expect(tracker.placement(of: "top") == .inView)
        #expect(tracker.placement(of: "bottom") == .inView)
        #expect(tracker.placement(of: "below") == .below)
        #expect(tracker.placement(of: "elsewhere") == .notShown)
        #expect(tracker.timesInView == 20 ... 30)
    }
}
