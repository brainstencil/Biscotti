import AppCore
import DataStore
import Foundation

/// State for the People sheet (ui_design.md §3).
@MainActor @Observable
public final class PeopleListModel: Identifiable {
    private let core: AppCore

    public private(set) var rows: [PersonOverviewData] = []
    public private(set) var isLoaded = false
    public var filter = ""
    /// Non-nil while the person editor is open.
    public var editor: PersonEditorModel?

    public init(core: AppCore) {
        self.core = core
    }

    /// The core, for hosts that build editors or navigate.
    public var appCore: AppCore {
        core
    }

    /// Rows matching the filter (case-insensitive substring of name or email).
    public var filteredRows: [PersonOverviewData] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rows }
        return rows.filter {
            $0.person.name.localizedCaseInsensitiveContains(query)
                || ($0.person.email?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public var emptyText: String {
        PeopleCopy.peopleEmpty
    }

    public var noMatchText: String {
        PeopleCopy.noMatch(filter.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func metaText(_ row: PersonOverviewData) -> String {
        PeopleCopy.overviewMeta(row)
    }

    public func deleteHelp(_ row: PersonOverviewData) -> String {
        PeopleCopy.deleteHelp(meetingCount: row.meetingCount)
    }

    public func load() async {
        rows = await (try? core.peopleOverview()) ?? []
        isLoaded = true
    }

    /// Deletes an unused person. If the store refuses (the person gained a
    /// use, or is already gone), the list reloads to show the current state.
    public func delete(_ row: PersonOverviewData) async {
        guard row.meetingCount == 0 else { return }
        try? await core.deleteUnusedPerson(id: row.id)
        await load()
    }

    public func edit(_ row: PersonOverviewData) {
        editor = PersonEditorModel(core: core, personID: row.id)
    }

    /// Call when the editor sheet closes. Reloads if anything changed.
    public func editorDidClose() async {
        let changed = editor?.didChange ?? false
        editor = nil
        if changed { await load() }
    }
}
