import DataStore
import Foundation
import MeetingChat

/// The History menu's threads: most recently used first, each with its name and the time of its last question or answer,
/// the open one checked.
struct ChatHistoryPresentation: Equatable {
    struct Item: Equatable, Identifiable {
        let id: UUID
        let title: String
        /// "5:21 PM" today, "Oct 26" on earlier days.
        let time: String
        let isOpen: Bool
    }

    let items: [Item]

    /// "Chat history, [thread name]" while a thread is open.
    var accessibilityLabel: String {
        guard let open = items.first(where: \.isOpen) else { return "Chat history" }
        return "Chat history, \(open.title)"
    }

    @MainActor
    static func make(state: MeetingChatState, now: Date = Date()) -> Self {
        make(threads: state.threads, openThreadID: state.openThreadID, now: now)
    }

    static func make(
        threads: [ChatThreadSummary],
        openThreadID: UUID?,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Self {
        let newestFirst = threads.enumerated()
            .sorted { $0.element.updatedAt != $1.element.updatedAt ? $0.element.updatedAt > $1.element.updatedAt : $0.offset < $1.offset }
            .map(\.element)
        return Self(items: newestFirst.map { thread in
            Item(
                id: thread.id,
                title: thread.title,
                time: timeText(thread.updatedAt, now: now, calendar: calendar, locale: locale),
                isOpen: thread.id == openThreadID
            )
        })
    }

    /// The time of day for today, the month and day for earlier days.
    static func timeText(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            return date.formatted(style)
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated)
            .day()
        return date.formatted(style)
    }
}
