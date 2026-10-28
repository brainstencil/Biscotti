import DataStore
import Foundation
import Testing
@testable import MeetingChat
@testable import MeetingChatUI

@Suite("Chat History menu")
struct ChatHistoryPresentationTests {
    private let meetingID = UUID()

    private func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        return calendar
    }

    private func date(_ calendar: Calendar, day: Int, hour: Int, minute: Int) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)))
    }

    private func thread(_ title: String, updatedAt: Date) -> ChatThreadSummary {
        ChatThreadSummary(id: UUID(), meetingID: meetingID, title: title, createdAt: updatedAt, updatedAt: updatedAt)
    }

    @Test("threads list newest first, the open one checked, with today's time or an earlier day")
    func historyItemsNewestFirst() throws {
        let calendar = try calendar()
        let now = try date(calendar, day: 28, hour: 18, minute: 2)
        let older = try thread("What did we decide about the beta?", updatedAt: date(calendar, day: 26, hour: 9, minute: 15))
        let today = try thread("Who owns the release notes?", updatedAt: date(calendar, day: 28, hour: 17, minute: 21))
        let yesterday = try thread("Draft a follow-up email", updatedAt: date(calendar, day: 27, hour: 23, minute: 50))

        let history = ChatHistoryPresentation.make(
            threads: [older, today, yesterday],
            openThreadID: yesterday.id,
            now: now,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )

        #expect(history.items.map(\.title) == [today.title, yesterday.title, older.title])
        #expect(history.items.map(\.isOpen) == [false, true, false])
        // ICU writes a narrow no-break space before "PM".
        #expect(history.items[0].time.replacingOccurrences(of: "\u{202F}", with: " ") == "5:21 PM")
        #expect(history.items[1].time == "Oct 27")
        #expect(history.items[2].time == "Oct 26")
        #expect(history.accessibilityLabel == "Chat history, Draft a follow-up email")
    }

    @Test("with no open thread the History button reads \"Chat history\"")
    @MainActor
    func historyFromState() {
        let state = MeetingChatState(meetingID: meetingID) { _ in .available }
        #expect(ChatHistoryPresentation.make(state: state).items.isEmpty)
        #expect(ChatHistoryPresentation.make(state: state).accessibilityLabel == "Chat history")

        let open = thread("Who owns the release notes?", updatedAt: Date())
        state.threads = [open]
        state.openThreadID = open.id
        #expect(ChatHistoryPresentation.make(state: state).items.map(\.isOpen) == [true])
    }
}
