import CoreGraphics
import Testing
@testable import MeetingChatUI

@Suite("Chat list following new text")
struct ChatScrollFollowTests {
    private func place(_ offset: CGFloat, content: CGFloat, container: CGFloat = 400) -> ScrollPlace {
        ScrollPlace(
            offset: offset,
            isAtBottom: offset + container >= content - ChatMessageList.bottomTolerance,
            contentHeight: content,
            containerHeight: container
        )
    }

    @Test("a second question that makes a fitting thread outgrow the card keeps following and scrolls to the end")
    func outgrowingTheCardKeepsFollowing() {
        // The first answer fits: the content sits at the card's bottom.
        let fitting = place(-50, content: 350)
        #expect(fitting.isAtBottom)
        // The question and its status line make it outgrow the card; the
        // scroll view keeps the content where it was, and its offset moves up.
        let outgrown = place(-60, content: 470)
        #expect(!outgrown.isAtBottom)

        #expect(outgrown.follows(after: fitting, wasFollowing: true))
        #expect(outgrown.needsScrollToEnd(after: fitting, isFollowing: true))
    }

    @Test("a row measured after the last scroll to the end scrolls to the end again")
    func rowMeasuredLaterScrollsAgain() {
        let atEnd = place(600, content: 1000)
        let grown = place(600, content: 1040)
        #expect(grown.follows(after: atEnd, wasFollowing: true))
        #expect(grown.needsScrollToEnd(after: atEnd, isFollowing: true))
    }

    @Test("scrolling up stops the following; new text below then leaves the list where the user put it")
    func scrollingUpStops() {
        let atEnd = place(600, content: 1000)
        let scrolledUp = place(450, content: 1000)
        let stopped = scrolledUp.follows(after: atEnd, wasFollowing: true)
        #expect(!stopped)

        let moreText = place(450, content: 1040)
        #expect(!moreText.follows(after: scrolledUp, wasFollowing: stopped))
        #expect(!moreText.needsScrollToEnd(after: scrolledUp, isFollowing: false))
    }

    @Test("a scroll up that arrives with new text below stops the following")
    func scrollUpWithNewTextStops() {
        let atEnd = place(600, content: 1000)
        // The same update carries the user's scroll and a wrapped line (or a
        // row measured as the user scrolls toward it).
        let scrolledUpAndGrown = place(450, content: 1030)
        let follows = scrolledUpAndGrown.follows(after: atEnd, wasFollowing: true)
        #expect(!follows)
        #expect(!scrolledUpAndGrown.needsScrollToEnd(after: atEnd, isFollowing: follows))
    }

    @Test("reaching the end follows again; resizing the card does not count as scrolling")
    func endAndResize() {
        let scrolledUp = place(450, content: 1000)
        let backAtEnd = place(600, content: 1000)
        #expect(backAtEnd.follows(after: scrolledUp, wasFollowing: false))

        let atEnd = place(600, content: 1000)
        // Dragged taller, the scroll view moves the offset up and leaves the end out of view.
        let taller = place(400, content: 1000, container: 520)
        #expect(!taller.isAtBottom)
        #expect(taller.follows(after: atEnd, wasFollowing: true))
        #expect(taller.needsScrollToEnd(after: atEnd, isFollowing: true))
        let shorter = place(560, content: 1000, container: 300)
        #expect(shorter.follows(after: atEnd, wasFollowing: true))
        #expect(shorter.needsScrollToEnd(after: atEnd, isFollowing: true))
        // Resizing a list the user scrolled up does not start the following.
        #expect(!place(380, content: 1000, container: 520).follows(after: scrolledUp, wasFollowing: false))
    }

    @Test("a small move up within a point is not a scroll")
    func jitterIsNotAScroll() {
        let before = place(500, content: 1000)
        let after = place(499.5, content: 1000)
        #expect(after.follows(after: before, wasFollowing: true))
        #expect(!after.needsScrollToEnd(after: before, isFollowing: true))
    }
}
