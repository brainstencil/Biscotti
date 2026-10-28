import AppCore
import DataStore
import Foundation

/// Another person that a save would collide with.
public enum PersonCollision: Equatable, Sendable {
    case name(PersonData)
    /// The (normalized) email and the person who already has it.
    case email(String, PersonData)

    public var person: PersonData {
        switch self {
        case let .name(person), let .email(_, person): person
        }
    }
}

/// State for the person editor sheet: edit mode, the collision banner,
/// and merge mode (functional spec §3, §5; ui_design.md §4).
@MainActor @Observable
public final class PersonEditorModel: Identifiable {
    /// The person being edited.
    public let id: UUID
    private let core: AppCore
    private let countsDelay: Duration

    public private(set) var savedName = ""
    public private(set) var savedEmail: String?
    public private(set) var meetings: [PersonMeetingData] = []
    public private(set) var isLoaded = false

    public var nameText = "" {
        didSet {
            guard nameText != oldValue else { return }
            if case .name = collision { collision = nil }
            scheduleCountsRefresh()
        }
    }

    public var emailText = "" {
        didSet {
            guard emailText != oldValue else { return }
            if case .email = collision { collision = nil }
        }
    }

    /// Whether to replace the old name in summaries and titles. On by default.
    public var replaceInText = true
    public private(set) var replacementCounts = TextReplacementCounts(summaries: 0, titles: 0)

    public private(set) var collision: PersonCollision?
    /// Non-nil while the sheet is in merge mode.
    public var mergeDraft: MergeDraft?

    /// The person was merged away or deleted elsewhere.
    public private(set) var isMissing = false
    public private(set) var errorMessage: String?
    /// Set after a successful save or merge, so the host knows to reload.
    public private(set) var didChange = false

    private var countsTask: Task<Void, Never>?

    public init(core: AppCore, personID: UUID, countsDelay: Duration = .milliseconds(250)) {
        id = personID
        self.core = core
        self.countsDelay = countsDelay
    }

    // MARK: - Derived

    var normalizedName: String {
        PersonFieldRules.normalizeName(nameText)
    }

    var normalizedEmail: String? {
        PersonFieldRules.normalizeEmail(emailText)
    }

    public var nameChanged: Bool {
        isLoaded && normalizedName != savedName
    }

    public var hasChanges: Bool {
        nameChanged || normalizedEmail != savedEmail?.lowercased()
    }

    public var nameError: String? {
        guard isLoaded else { return nil }
        return PersonFieldRules.validateName(normalizedName).map(PeopleCopy.fieldError)
    }

    public var emailError: String? {
        guard isLoaded else { return nil }
        return PersonFieldRules.validateEmail(normalizedEmail).map(PeopleCopy.fieldError)
    }

    public var canSave: Bool {
        isLoaded && !isMissing && hasChanges && nameError == nil && emailError == nil
    }

    public var showsReplaceToggle: Bool {
        nameChanged && !replacementCounts.isEmpty
    }

    public var replaceLabel: String {
        PeopleCopy.replaceLabel(old: savedName, new: normalizedName, counts: replacementCounts)
    }

    public var replaceOffCaption: String {
        PeopleCopy.replaceOffCaption(old: savedName)
    }

    public var meetingsHeading: String {
        PeopleCopy.meetingsHeading(meetings.count)
    }

    public func rolesText(_ meeting: PersonMeetingData) -> String {
        PeopleCopy.roles(meeting.roles)
    }

    public var collisionTitle: String? {
        collision.map(PeopleCopy.collisionTitle)
    }

    public var collisionHelp: String {
        PeopleCopy.collisionHelp
    }

    public var mergeButtonTitle: String? {
        collision.map(PeopleCopy.mergeButton)
    }

    // MARK: - Loading

    public func load() async {
        do {
            guard let person = try await core.store.allPersonData().first(where: { $0.id == id }) else {
                isMissing = true
                return
            }
            savedName = person.name
            savedEmail = person.email
            meetings = try await core.personMeetings(id: id)
            isLoaded = true
            nameText = person.name
            emailText = person.email ?? ""
        } catch PersonEditError.notFound {
            isMissing = true
        } catch {
            errorMessage = PeopleCopy.saveFailed
        }
    }

    private func scheduleCountsRefresh() {
        countsTask?.cancel()
        guard nameChanged else {
            replacementCounts = TextReplacementCounts(summaries: 0, titles: 0)
            return
        }
        let delay = countsDelay
        countsTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshReplacementCounts()
        }
    }

    /// Recomputes how many summaries and titles the rename would change.
    func refreshReplacementCounts() async {
        let newName = normalizedName
        guard nameChanged else {
            replacementCounts = TextReplacementCounts(summaries: 0, titles: 0)
            return
        }
        let counts = try? await core.replacementCounts(
            personID: id, oldName: savedName, newName: newName
        )
        // Drop a stale result if the user kept typing.
        guard newName == normalizedName else { return }
        replacementCounts = counts ?? TextReplacementCounts(summaries: 0, titles: 0)
    }

    // MARK: - Saving

    /// Saves the edit. Returns true when the sheet should close.
    public func save() async -> Bool {
        guard canSave else { return false }
        errorMessage = nil
        do {
            try await core.updatePerson(
                id: id, name: nameText, email: emailText,
                replaceInText: replaceInText && nameChanged
            )
            didChange = true
            return true
        } catch let error as PersonEditError {
            handle(error)
            return false
        } catch {
            errorMessage = PeopleCopy.saveFailed
            return false
        }
    }

    /// Hides the collision banner so the user can choose a different value.
    public func keepEditing() {
        collision = nil
    }

    private func handle(_ error: PersonEditError) {
        switch error {
        case .notFound:
            isMissing = true
            errorMessage = PeopleCopy.missingPerson
        case let .nameCollision(person):
            collision = .name(person)
        case let .emailCollision(person):
            collision = .email(normalizedEmail ?? "", person)
        case .invalid, .inUse:
            // Validated locally before saving; not expected here.
            errorMessage = PeopleCopy.saveFailed
        }
    }

    // MARK: - Merge

    /// Switches to merge mode with the colliding person as the target.
    public func beginMerge() async {
        guard let target = collision?.person else { return }
        let source = PersonData(id: id, name: savedName, email: savedEmail)
        var draft = MergeDraft(
            source: source, target: target,
            typedName: normalizedName, typedEmail: normalizedEmail,
            sourceMeetingCount: meetings.count
        )
        draft.sharedMeetings = await (try? core.sharedTranscriptMeetings(id, target.id)) ?? []
        mergeDraft = draft
        await refreshMergeCounts()
    }

    /// Chooses the surviving name and refreshes the replacement counts.
    public func chooseMergeName(_ name: String) async {
        mergeDraft?.name = name
        await refreshMergeCounts()
    }

    func refreshMergeCounts() async {
        guard let draft = mergeDraft else { return }
        let sourceCounts = try? await core.replacementCounts(
            personID: draft.source.id, oldName: draft.source.name, newName: draft.name
        )
        let targetCounts = try? await core.replacementCounts(
            personID: draft.target.id, oldName: draft.target.name, newName: draft.name
        )
        guard mergeDraft?.name == draft.name else { return }
        mergeDraft?.sourceCounts = sourceCounts ?? TextReplacementCounts(summaries: 0, titles: 0)
        mergeDraft?.targetCounts = targetCounts ?? TextReplacementCounts(summaries: 0, titles: 0)
    }

    /// Leaves merge mode, keeping the typed values and the collision.
    public func cancelMerge() {
        mergeDraft = nil
    }

    /// Performs the merge. Returns true when the sheet should close.
    public func confirmMerge() async -> Bool {
        guard let draft = mergeDraft else { return false }
        errorMessage = nil
        do {
            try await core.mergePeople(
                sourceID: draft.source.id, targetID: draft.target.id,
                choice: draft.choice
            )
            didChange = true
            return true
        } catch let PersonEditError.emailCollision(person) {
            errorMessage = PeopleCopy.collisionTitle(.email(draft.email ?? "", person))
            return false
        } catch let error as PersonEditError {
            handle(error)
            return false
        } catch {
            errorMessage = PeopleCopy.saveFailed
            return false
        }
    }
}
