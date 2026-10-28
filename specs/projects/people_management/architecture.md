---
status: complete
---

# Architecture: People Management

This is a single-document architecture. It adds one new UI module, `PeopleUI`, and one new
`DataStore` file group. It also wires into `AppCore`, `SettingsUI`, and `MeetingDetailUI`. The
persisted schema does not change.

## 1. Topology

```
           SettingsUI ───────┐            ┌──────── MeetingDetailUI
   (People row + sheet host) │            │ (✎ in speaker sheet, editor host)
                             ▼            ▼
                       ┌──────────────────────┐
                       │   PeopleUI (NEW)     │  PeopleListSheet, PersonEditorSheet,
                       │                      │  PeopleListModel, PersonEditorModel
                       └──────────┬───────────┘
                                  │ AppCore+People (pass-throughs + reloadSummaries)
                                  ▼
                       ┌──────────────────────┐
                       │      DataStore       │  DataStore+People.swift (queries, mutations)
                       │                      │  People/PersonFieldRules.swift (pure)
                       │                      │  People/NameReplacement.swift (pure)
                       └──────────────────────┘
```

- **`DataStore` owns every rule that must hold atomically:** validation, collision detection, the
  rename with its text replacement, merge, and delete-if-unused. Each mutation is one actor call
  and one `save()`. A concurrent AI naming write cannot land halfway through a merge.
- **The pure helpers live in `DataStore`**, because the store needs them inside the transaction
  and the UI needs the same rules for inline messages. They are `public`, free of SwiftData, and
  unit-tested on their own.
- **`PeopleUI`** depends on `AppCore`, `AppLinks`, `DataStore`, `DesignSystem`, and `Formatting`.
  Both hosts already depend on everything it needs. It goes in its own module, as
  `SummaryPromptUI` does, because two feature UIs share it.
- **`AppCore+People.swift`** gives the UI one place to call. After any change that can alter a
  title, it refreshes `summaries` (the meeting list) through `reloadSummaries()`. The UI never calls
  the store directly, following the `SettingsViewModel` → `core.store` pattern used elsewhere.

## 2. Data model

No schema change. The existing fields are:

- `Person`: `id`, `name`, `email?`, plus the inverses `meetings` and `organizedMeetings`.
- `Meeting`: `title`, `editedTitle`, `summary`, `editedSummary`, `startDate?`, `createdAt`,
  `participants`, `organizer`, `transcripts` (no inverse), and `calendarSnapshot`
  (`currentUserPersonID`).
- `TranscriptRecord.speakerAssignments`: `[Int: SpeakerAssignmentEntry]`, JSON-backed.
- `Voiceprint`: untouched.

`TranscriptRecord` has no relationship back to its meeting. Every "a person's meetings" query
therefore walks `Meeting.transcripts`. At library scale (hundreds of meetings, about one
transcript each) one pass is cheap. §3.3 does the pass once per call.

## 3. `DataStore`

### 3.1 `People/PersonFieldRules.swift` (pure, public)

```swift
public enum PersonFieldRules {
    public static let maxNameLength = 120
    /// Trims, then collapses internal whitespace runs to one space.
    public static func normalizeName(_ raw: String) -> String
    /// nil when valid. Checked on the normalized name.
    public static func validateName(_ normalized: String) -> PersonFieldError?
    /// Trims and lowercases. An empty result means "no email".
    public static func normalizeEmail(_ raw: String) -> String?
    /// nil when valid (or empty). Exactly one "@", non-empty sides, no whitespace.
    public static func validateEmail(_ normalized: String?) -> PersonFieldError?
    /// Case-insensitive (localized standard) comparison used for collisions.
    public static func namesCollide(_ lhs: String, _ rhs: String) -> Bool
}

public enum PersonFieldError: Error, Equatable, Sendable {
    case emptyName, nameTooLong, invalidEmail
}
```

`maxNameLength` applies to user edits only. AI speaker naming has no name cap (the 120 in
`MeetingAnalyzer.cleanTitle` is the *title* cap), so this project does not touch `Intelligence`.

### 3.2 `People/NameReplacement.swift` (pure, public)

```swift
public enum NameReplacement {
    /// Number of replaceable occurrences of `old` in `text`.
    public static func count(of old: String, replacingWith new: String, in text: String) -> Int
    /// `text` with every replaceable occurrence of `old` changed to `new`.
    public static func apply(old: String, new: String, to text: String) -> String
}
```

An occurrence is **replaceable** when all of these hold:

1. It matches `old` exactly (case-sensitive, literal).
2. It sits on word boundaries. The character before it and the character after it are each either
   absent or not a letter, digit, or `_` (Unicode-aware: `Character.isLetter` / `isNumber`). So
   `Steven's`, `**Steven**`, and `Steven,` match, and `Stevenson` does not.
3. It is not inside an occurrence of `new` or of any `protecting` name in the original text. All
   those ranges are found first, and any `old` occurrence whose range lies within one of them is
   skipped. This keeps `Paul` → `Paul Kowalski` from rewriting an existing `Paul Kowalski`.

The store passes as `protecting` every **other** person's name that contains the old name
(`protectedNames(containing:excluding:)`). Renaming "Paul" to "Pablo" therefore leaves a "Paul
Kowalski" who is a different person intact. In a merge, the same rule keeps the source pass from
rewriting the target's longer name before the target pass sees it. `replacementCounts` uses the
same protection and normalizes the new name, so the counts the editor shows match what the save
changes.

If `old == new`, both functions are no-ops. This is plain string scanning with no regex. Names
can contain regex metacharacters, so there is nothing to escape this way.

### 3.3 `DataStore+People.swift`: read models and queries

```swift
public struct PersonRoles: OptionSet, Sendable, Hashable {
    public static let speaker, attendee, organizer
}

public struct PersonMeetingData: Sendable, Identifiable, Equatable {
    public let id: UUID            // meeting id
    public let title: String
    public let date: Date          // startDate ?? createdAt
    public let roles: PersonRoles
}

public struct PersonOverviewData: Sendable, Identifiable, Equatable {
    public let person: PersonData
    public let meetingCount: Int
    public let lastSeen: Date?
    public var id: UUID { person.id }
}

public struct TextReplacementCounts: Sendable, Equatable {
    public let summaries: Int      // meetings whose summary has ≥1 replaceable occurrence
    public let titles: Int
    public var isEmpty: Bool { summaries == 0 && titles == 0 }
}

public extension DataStore {
    func peopleOverview() throws -> [PersonOverviewData]          // sorted by name, case-insensitive
    func personMeetings(id: UUID) throws -> [PersonMeetingData]   // newest first; throws notFound
    func replacementCounts(personID: UUID, oldName: String, newName: String) throws
        -> TextReplacementCounts
    func sharedTranscriptMeetings(_ a: UUID, _ b: UUID) throws -> [PersonMeetingData]
}
```

**One internal index builder** serves all four queries:

```swift
/// personID → (meetingID → roles), built from one pass over all meetings.
func personUseIndex() throws -> [UUID: [UUID: PersonRoles]]
```

For each `Meeting`, the builder adds:

- `.speaker` for every person in any transcript's `speakerAssignments`. This covers every
  transcript version, not only the preferred one.
- `.attendee` for every person in `participants`.
- `.organizer` for the organizer.

Dangling person ids (from assignments) are kept in the index but never matched to a `Person`, so
they are ignored. `peopleOverview()` builds the index once and folds it per person.

`sharedTranscriptMeetings(a, b)` lists the meetings with at least one transcript where `a` and `b`
are assigned to **different** speakers. This is the same-transcript merge warning.

### 3.4 `DataStore+People.swift`: mutations

```swift
public enum PersonEditError: Error, Equatable, Sendable {
    case notFound
    case invalid(PersonFieldError)
    case nameCollision(PersonData)
    case emailCollision(PersonData)
    case inUse(meetingCount: Int)
}

/// The surviving person's name and email, and whether each old name is
/// replaced in its own person's summaries and titles.
public struct PersonMergeChoice: Sendable, Equatable {
    public let name: String
    public let email: String?
    public let replaceSourceName: Bool
    public let replaceTargetName: Bool
}

public extension DataStore {
    /// Rename and/or change email. Name collision is checked before email collision.
    func updatePerson(id: UUID, name: String, email: String?, replaceInText: Bool) throws

    func mergePeople(sourceID: UUID, targetID: UUID, choice: PersonMergeChoice) throws

    func deleteUnusedPerson(id: UUID) throws
}
```

**`updatePerson`**:

1. Fetch the person, or throw `.notFound`.
2. Normalize both fields and validate them, throwing `.invalid(…)` on failure.
3. If the normalized name differs from the stored name (case-sensitive), look for **another**
   person where `namesCollide`. If one exists, throw `.nameCollision(that)`. If the name is
   unchanged, skip the check (functional spec §7: existing duplicate pairs do not block an email
   edit).
4. If the normalized email is non-nil and differs from the stored one, look for another person with
   that email (case-insensitive). If one exists, throw `.emailCollision(that)`.
5. If `replaceInText` is true and the name changed, run `applyNameReplacement(old:new:in:)` over
   the person's meetings (from `personUseIndex()`): `meeting.summary` and `meeting.title`. The
   `editedSummary` and `editedTitle` flags stay as they are.
6. Set the name and email, then `save()` once.

Steps 3 and 4 run in the actor before anything is written. A collision therefore leaves the store
untouched.

**`mergePeople`**:

1. Fetch the source and target, or throw `.notFound`. Normalize and validate the chosen name and
   email.
2. Build the use index once. Run text replacement first, while each person's meeting set is still
   their own:
   - If `replaceSourceName` is true and the source name differs from the final name, replace it in
     the source's meetings.
   - If `replaceTargetName` is true and the target name differs from the final name, replace it in
     the target's meetings.
3. For every meeting, `repointUses(in:from:to:)` moves all of the source's uses to the target:
   - assignment entries in every transcript (keeping `userSet`; only changed transcripts are
     re-encoded);
   - `participants` (source removed, target appended if absent);
   - `organizer`;
   - `calendarSnapshot.currentUserPersonID`.
4. Set the target's name and email. Run `context.delete(source)`. Then `save()` once.

The chosen name and email are **not** collision-checked against third people. The user picked
them from the two records being merged, or typed them in the editor that led here, and the editor
already checked the typed name against everyone else.

**`deleteUnusedPerson`**: fetch the person, or throw `.notFound`. Count the person's meetings from
the index. If the count is above 0, throw `.inUse(meetingCount:)`. Otherwise delete the person and
save. The existing test-only `deletePerson(id:)` in `DataStore+Voiceprints.swift` stays as it is.

### 3.5 Search index

`title`, `summary`, and `people` are FTS columns, and the history-token sync reindexes a meeting
when its `Meeting` row or a related `Person` or `Tag` changes (`DataStore+ReadModels`
incremental sync).

**Pre-existing bug fixed here.** `collectAffectedMeetings` resolved each changed identifier by
trying a `Meeting` fetch first. A `persistentModelID` predicate matches on the row's primary key,
so a `Person` (or `Tag`) identifier also fetched the unrelated `Meeting` with the same key and
returned early. The person's own meetings were never reindexed. The same bug affected tag renames.
The fix dispatches on `pid.entityName`. An on-disk test (with real history) covers a rename and a
merge; in-memory stores always run a full reconcile and cannot catch this.

## 4. `AppCore+People.swift`

```swift
public extension AppCore {
    func peopleOverview() async throws -> [PersonOverviewData]
    func personMeetings(id: UUID) async throws -> [PersonMeetingData]
    func replacementCounts(personID: UUID, oldName: String, newName: String) async throws
        -> TextReplacementCounts
    func sharedTranscriptMeetings(_ a: UUID, _ b: UUID) async throws -> [PersonMeetingData]
    func updatePerson(id: UUID, name: String, email: String?, replaceInText: Bool) async throws
    func mergePeople(sourceID: UUID, targetID: UUID, choice: PersonMergeChoice) async throws
    func deleteUnusedPerson(id: UUID) async throws
    /// Bumped after every successful people mutation. Open views observe it to reload.
    var peopleVersion: Int { get }
}
```

After a successful mutation, `AppCore` bumps `peopleVersion`. If titles could have changed
(`replaceInText`, or a merge), it also calls `reloadSummaries()`. `peopleVersion` is a stored
property, so it goes in the `@Observable` class body. Mind the `type_body_length` lint limit:
follow the extraction pattern the file already uses.

## 5. `PeopleUI`

### 5.1 `PersonEditorModel` (`@MainActor @Observable`)

- **Inputs:** `core: AppCore` and `personID`.
- **State:**
  - `savedName`, `savedEmail`, `nameText`, `emailText`, `meetings: [PersonMeetingData]`.
  - `replaceInText: Bool` (default `true`) and `replacementCounts`.
  - `collision: Collision?`, where `Collision` is `.name(PersonData)` or `.email(PersonData)`.
  - `mode: .edit | .merge(MergeDraft)`, and `missing: Bool`.
- **Derived:**
  - `nameError` and `emailError`, from `PersonFieldRules`.
  - `canSave`: valid and changed.
  - `showsReplaceToggle`: the name changed and the counts are not empty.
  - `replaceLabel` and `replaceOffCaption`, built from the copy in `ui_design.md` §5, singular or
    plural as needed.
- **Behaviour:**
  - `load()`.
  - `nameDidChange()` schedules a counts refresh 250 ms later and cancels the previous one.
  - `save() async -> Bool` maps `PersonEditError` to `collision`, `missing`, or field errors, and
    returns `true` when the sheet should close.
  - `beginMerge()` builds the `MergeDraft` and loads the shared-transcript meetings and both
    replacement counts.
  - `confirmMerge() async -> Bool`.
  - `cancelMerge()`.
- **`MergeDraft`** holds the source and target `PersonData`, the name options and choice, the email
  options and choice, `replaceSource`/`replaceTarget` with their counts, and `sharedMeetings`.
  Option building and the default rules are pure static functions on `MergeDraft`, so tests do not
  need a store.

### 5.2 `PeopleListModel` (`@MainActor @Observable`)

It holds `rows: [PersonOverviewData]` and `filter`. `filtered` is computed. `load()` reads the
rows. `delete(_:)` reloads after any outcome, so a refused delete leaves the row in place with
its new count. `editor: PersonEditorModel?` drives the editor sheet.

### 5.3 Views

- `PersonEditorSheet(model:onOpenMeeting:onClose:)` renders edit mode, the collision banner, and
  merge mode, following `ui_design.md` §4.
- `PeopleListSheet(model:onOpenMeeting:)` renders `ui_design.md` §3 and presents
  `PersonEditorSheet` with `.sheet(item:)`.
- `onOpenMeeting: (UUID) -> Void` is the host's job. The sheets never navigate on their own.

## 6. Host wiring

### 6.1 `SettingsUI`

- New file `SettingsPeopleSection.swift`, with `peopleSection` and its row, following
  `SettingsVocabularySection`.
- `SettingsViewModel` gains `peopleCount`. `reloadPeopleCount()` lives in
  `SettingsViewModel+People.swift` (the class body is at its lint size limit) and runs when the
  section appears and when the People sheet closes.
- `sectionTitles` gets `"People"` inserted at index 5. Re-index the Import/Export (6) and Calendars
  (7) references and update the Settings title tests.
- `onOpenMeeting` dismisses the sheets, then calls
  `Task { await core.apply(.meeting(id:, target: .tab(.transcript))) }`. `select` changes the route
  to `.meetings`.
- `Package.swift`: `SettingsUI` gains the dependencies `PeopleUI` and `AppLinks`.

### 6.2 `MeetingDetailUI`

- `SpeakerMappingSheet` gains `onEditPerson: (PersonData) -> Void`, and shows the ✎ button on
  assigned rows.
- `MeetingDetailViewModel` gains `editingPerson: PersonEditorModel?`, which drives
  `.sheet(item:)` on top of the speaker sheet.
  - **Before** it opens the editor, it flushes any pending summary or title autosave
    (`saveSummary()`, and the same for the title). Otherwise a debounced write could overwrite the
    replacement.
  - **After** any people edit, the view's `.onChange(of: viewModel.peopleVersion)` calls
    `reloadAfterPeopleChange()`: the existing `reloadAfterSpeakerChange()` (transcript and sheet
    rows) plus `refreshData()` (summary, title, participants). This one path also covers edits
    made in Settings while a meeting is open.
- `onOpenMeeting` clears `editingPerson` and `speakerSheetTranscriptID`, then calls
  `core.apply(.meeting(…))`. If the meeting is the current one, the speaker sheet just closes.
- `Package.swift`: `MeetingDetailUI` (and its test target) gain the dependency `PeopleUI`.

## 7. Testing

| Layer | Tests |
|---|---|
| `PersonFieldRules` | normalize (trim, collapse, unicode spaces), length 120/121, email shapes, collide casing |
| `NameReplacement` | word boundaries, possessive, markdown emphasis, `Stevenson` untouched, expansion skip (`Paul` → `Paul Kowalski`), no-op when equal, counts match apply |
| `DataStore+People` (in-memory store) | overview counts and last seen across versions, attendee and organizer; personMeetings roles and order; update: rename, case-only rename, email set and clear, name collision before email collision, no collision on unchanged duplicate name, replacement on and off, flags kept, notFound; merge: assignments in all versions keep `userSet`, attendee dedup, organizer, currentUserPersonID, source deleted, replacement per old name, voiceprints untouched, shared-transcript list; delete: unused OK, in use refused; search reindex after rename |
| `PeopleUI` models | label and plural copy, debounce, error mapping, MergeDraft options and defaults, list filter, delete refused |
| `SettingsUI` | section titles and indices, people count |
| `MeetingDetailUI` | flush-before-edit, reload after save |

No packages on the manual-test staleness list (`Transcription`, `AudioCapture`, `LocalLLM`,
`MCPServer`) are touched, so `manual_test_results.json` does not change.
