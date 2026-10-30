import CoreGraphics
import Testing
@testable import TranscriptUI

@Suite("VisibleRowTracker")
struct VisibleRowTrackerTests {
    @Test("the top visible item is the first row whose middle is on screen")
    func topVisibleIsFirstRowWhoseMiddleIsOnScreen() {
        let tracker = VisibleRowTracker()
        tracker.updateHeader(height: 300)
        tracker.updateScroll(offsetY: 900, insetTop: 0)
        // Overscanned above, mostly scrolled off, on screen, and below.
        tracker.update(id: "above", startTime: 10, frame: CGRect(x: 0, y: -120, width: 100, height: 50))
        tracker.update(id: "mostlyOff", startTime: 20, frame: CGRect(x: 0, y: -40, width: 100, height: 50))
        tracker.update(id: "top", startTime: 30, frame: CGRect(x: 0, y: 14, width: 100, height: 50))
        tracker.update(id: "next", startTime: 40, frame: CGRect(x: 0, y: 70, width: 100, height: 50))

        #expect(tracker.topVisibleStartTime == 30)

        tracker.remove(id: "top")
        #expect(tracker.topVisibleStartTime == 40)
    }

    @Test("the drawer: a list 540 pt down the window reads its rows from its own top")
    func drawerListOffsetInTheWindow() {
        let tracker = VisibleRowTracker()
        // Frames in the window, as the rows and the list report them.
        tracker.updateList(frame: CGRect(x: 300, y: 540, width: 880, height: 431))
        tracker.updateScroll(offsetY: 45000, insetTop: 0, viewportHeight: 431)
        tracker.updateHeader(height: 0)
        tracker.update(id: "overscan", startTime: 70, frame: CGRect(x: 320, y: 480, width: 600, height: 50))
        tracker.update(id: "cited", startTime: 77.9, frame: CGRect(x: 320, y: 540, width: 600, height: 40))
        tracker.update(id: "next", startTime: 80, frame: CGRect(x: 320, y: 590, width: 600, height: 40))
        tracker.update(id: "below", startTime: 120, frame: CGRect(x: 320, y: 971, width: 600, height: 40))

        #expect(tracker.placement(of: "cited") == .inView)
        #expect(tracker.placement(of: "overscan") == .above)
        #expect(tracker.placement(of: "below") == .below)
        #expect(tracker.timesInView == 77.9 ... 80)
        #expect(tracker.topVisibleStartTime == 77.9)
        #expect(tracker.visibleSpan.description
            == "77.9–80.0 s (view 431 pt, list at 540 pt in the window, 431 pt high, insets 0 top, 0 bottom)")
    }

    @Test("the meeting page: a list at the window's top reads its rows as the window does")
    func meetingPageListAtTheWindowTop() {
        let page = VisibleRowTracker()
        page.updateList(frame: CGRect(x: 300, y: 0, width: 880, height: 1290))
        page.updateScroll(offsetY: 9000, insetTop: 52, insetBottom: 1032, viewportHeight: 1290)
        page.update(id: "cited", startTime: 632.6, frame: CGRect(x: 320, y: 60, width: 600, height: 40))
        page.update(id: "underToolbar", startTime: 620, frame: CGRect(x: 320, y: 10, width: 600, height: 40))
        page.update(id: "behindCard", startTime: 700, frame: CGRect(x: 320, y: 300, width: 600, height: 40))

        #expect(page.placement(of: "cited") == .inView)
        #expect(page.placement(of: "underToolbar") == .above)
        #expect(page.placement(of: "behindCard") == .below)
        #expect(page.visibleSpan.description
            == "632.6–632.6 s (view 1290 pt, list at 0 pt in the window, 1290 pt high, insets 52 top, 1032 bottom)")
    }

    @Test("a list down the window with insets: rows are read from the list's top, then the insets apply")
    func listOffsetWithInsets() {
        let tracker = VisibleRowTracker()
        tracker.updateList(frame: CGRect(x: 0, y: 100, width: 600, height: 800))
        tracker.updateScroll(offsetY: 3000, insetTop: 52, insetBottom: 200, viewportHeight: 800)
        // In the list's space: 30–50 (under the top inset), 52–92, 560–600, 600–640 (under the bottom inset).
        tracker.update(id: "underTop", startTime: 10, frame: CGRect(x: 0, y: 130, width: 600, height: 20))
        tracker.update(id: "atTop", startTime: 20, frame: CGRect(x: 0, y: 152, width: 600, height: 40))
        tracker.update(id: "atBottom", startTime: 30, frame: CGRect(x: 0, y: 660, width: 600, height: 40))
        tracker.update(id: "underBottom", startTime: 40, frame: CGRect(x: 0, y: 700, width: 600, height: 40))

        #expect(tracker.placement(of: "underTop") == .above)
        #expect(tracker.placement(of: "atTop") == .inView)
        #expect(tracker.placement(of: "atBottom") == .inView)
        #expect(tracker.placement(of: "underBottom") == .below)
        #expect(tracker.timesInView == 20 ... 30)
    }

    @Test("the list moves after its rows have reported: rows are read against its current top until they report again")
    func listMovesAfterItsRows() {
        let tracker = VisibleRowTracker()
        tracker.updateScroll(offsetY: 0, insetTop: 0, viewportHeight: 400)
        tracker.updateList(frame: CGRect(x: 0, y: 540, width: 600, height: 400))
        tracker.update(id: "row", startTime: 5, frame: CGRect(x: 0, y: 560, width: 600, height: 40))
        #expect(tracker.placement(of: "row") == .inView)

        // The list moves up 300 pt (the drawer settling); the row has not reported yet.
        tracker.updateList(frame: CGRect(x: 0, y: 240, width: 600, height: 400))
        #expect(tracker.placement(of: "row") == .inView, "read at 320 pt in a 400 pt view")
        tracker.updateList(frame: CGRect(x: 0, y: 100, width: 600, height: 400))
        #expect(tracker.placement(of: "row") == .below, "read at 460 pt: stale until the row reports")

        // The row reports its moved frame.
        tracker.update(id: "row", startTime: 5, frame: CGRect(x: 0, y: 120, width: 600, height: 40))
        #expect(tracker.placement(of: "row") == .inView)
    }

    @Test("while the header is visible there is no anchor")
    func headerVisibleGivesNoAnchor() {
        let tracker = VisibleRowTracker()
        tracker.update(id: "first", startTime: 0, frame: CGRect(x: 0, y: 300, width: 100, height: 50))
        #expect(tracker.topVisibleStartTime == nil)

        tracker.updateHeader(height: 280)
        tracker.updateScroll(offsetY: 279, insetTop: 0)
        #expect(tracker.topVisibleStartTime == nil)

        tracker.updateScroll(offsetY: 280, insetTop: 0)
        #expect(tracker.topVisibleStartTime == 0)
    }

    @Test("a jump past the header hides it without a header geometry report")
    func jumpPastHeaderHidesIt() {
        let tracker = VisibleRowTracker()
        tracker.updateHeader(height: 280)
        tracker.update(id: "deep", startTime: 600, frame: CGRect(x: 0, y: 10, width: 100, height: 50))

        // End or Page Down: only the scroll position is reported.
        tracker.updateScroll(offsetY: 5000, insetTop: 0)

        #expect(tracker.isHeaderVisible == false)
        #expect(tracker.topVisibleStartTime == 600)
    }
}

@Suite("VisibleRowTracker -- toolbar inset")
struct VisibleRowTrackerInsetTests {
    /// The app's layout: the `List` runs 52 pt under the toolbar, so at rest
    /// the content offset is -52 and the reader's top edge is y = 52.
    private let insetTop: CGFloat = 52

    @Test("rows under the toolbar are not the top visible row")
    func rowsUnderTheToolbarAreSkipped() {
        let tracker = VisibleRowTracker()
        tracker.updateHeader(height: 280)
        tracker.updateScroll(offsetY: 1000, insetTop: insetTop)
        // Rows 18 and 19 are under the toolbar; row 20 is the first one seen.
        tracker.update(id: "18", startTime: 72, frame: CGRect(x: 0, y: -14, width: 100, height: 33))
        tracker.update(id: "19", startTime: 76, frame: CGRect(x: 0, y: 19, width: 100, height: 33))
        tracker.update(id: "20", startTime: 80, frame: CGRect(x: 0, y: 52, width: 100, height: 33))
        tracker.update(id: "21", startTime: 84, frame: CGRect(x: 0, y: 85, width: 100, height: 33))

        #expect(tracker.topVisibleStartTime == 80)
    }

    @Test("the header counts as visible only while it shows below the toolbar")
    func headerUnderTheToolbarIsHidden() {
        let tracker = VisibleRowTracker()
        tracker.updateHeader(height: 280)
        tracker.update(id: "first", startTime: 0, frame: CGRect(x: 0, y: 300, width: 100, height: 33))

        // At rest: offset -52, the header's top is just below the toolbar.
        tracker.updateScroll(offsetY: -insetTop, insetTop: insetTop)
        #expect(tracker.isHeaderVisible)

        // The header's last point is just below the toolbar.
        tracker.updateScroll(offsetY: 280 - insetTop - 1, insetTop: insetTop)
        #expect(tracker.isHeaderVisible)

        // The header has scrolled fully under the toolbar.
        tracker.updateScroll(offsetY: 280 - insetTop, insetTop: insetTop)
        #expect(!tracker.isHeaderVisible)
        #expect(tracker.topVisibleStartTime == 0)
    }
}
