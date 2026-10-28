---
status: complete
---

# Phase 1: DataStore Rules, Queries, and Mutations

## Overview

This phase adds all people-management logic to `DataStore`:

- The pure field rules and the name-replacement scanner.
- One person-use index, built from a single pass over the meetings.
- The four read queries the UI needs.
- The three mutations. Each is one actor call with one `save()`.

This phase has no UI.

## Steps

1. **`Sources/DataStore/People/PersonFieldRules.swift`.** Add `PersonFieldRules` and
   `PersonFieldError` as defined in architecture §3.1.
   - Whitespace collapse uses `.whitespacesAndNewlines` as the separator set.
   - `namesCollide` compares with `caseInsensitiveCompare == .orderedSame` after normalization.

2. **`Sources/DataStore/People/NameReplacement.swift`.** Add `NameReplacement.count` and `.apply`
   as defined in architecture §3.2.
   - Scan with `String.ranges(of:)`, in literal, case-sensitive mode.
   - Check the word boundary on the `Character` before and after each match.
   - Collect all ranges of `new` first, then skip each `old` range that a `new` range contains.

3. **`Sources/DataStore/DataStore+People.swift`.**
   - Add `PersonRoles`, `PersonMeetingData`, `PersonOverviewData`, `TextReplacementCounts`, and
     `PersonEditError`.
   - Add the internal `personUseIndex()`, with a small internal struct that holds each meeting's
     title and date.
   - Add the queries `peopleOverview`, `personMeetings`, `replacementCounts`, and
     `sharedTranscriptMeetings`.
   - Add the mutations `updatePerson`, `mergePeople`, and `deleteUnusedPerson`, as described in
     architecture §3.4.

## Tests

**`Tests/DataStoreTests/PersonFieldRulesTests.swift`**
- `normalizeName` trims, collapses tabs and newlines, and keeps the inner casing.
- `validateName`: empty gives `.emptyName`, 120 characters is valid, 121 gives `.nameTooLong`.
- `normalizeEmail` trims and lowercases. Empty or whitespace input gives nil.
- `validateEmail`: nil is valid, `a@b` is valid. `ab`, `a@@b`, `@b`, `a@`, and `a b@c` are invalid.
- `namesCollide`: `Steven` and `steven` collide. `Steven` and `Stephen` do not.

**`Tests/DataStoreTests/NameReplacementTests.swift`**
- `Steven said` becomes `Stephen said`. `Steven's`, `**Steven**`, and `(Steven)` are all replaced.
- `Stevenson` and `SteveN` are left alone.
- Expansion: in `Paul and Paul Kowalski`, replacing `Paul` with `Paul Kowalski` gives
  `Paul Kowalski and Paul Kowalski`.
- `old == new` is a no-op with a count of 0.
- `count` equals the number of changed occurrences, across several cases.
- Unicode: `José` → `Josefina` respects the word boundary before `é`.

**`Tests/DataStoreTests/PersonManagementTests.swift`** (in-memory store)
- **Overview:**
  - Counts a speaker assignment in a non-preferred transcript version.
  - Counts attendee and organizer uses.
  - Gives `lastSeen` as `startDate ?? createdAt`.
  - Sorts names case-insensitively.
  - Gives an unused person a count of 0 and a nil `lastSeen`.
- **`personMeetings`:** sets the role flags, returns newest first, and throws `notFound`.
- **Update:**
  - Rename.
  - Case-only rename.
  - Set an email and clear it.
  - Invalid name and invalid email.
  - Name collision returns the other person and leaves the store unchanged.
  - With both a name and an email collision, the name collision comes first.
  - An email collision.
  - An unchanged name with a same-name duplicate does not collide.
  - `notFound`.
- **Replacement:**
  - With `replaceInText` on, summaries and titles in the person's meetings change. A meeting
    outside them is untouched. `editedSummary` and `editedTitle` are kept.
  - With it off, nothing changes.
  - `replacementCounts` matches what the replacement then changes.
- **Merge:**
  - Assignments in every version are re-pointed and keep `userSet`.
  - An attendee who is in both people's meetings ends up listed once.
  - The organizer is moved, and `currentUserPersonID` is moved.
  - The source is deleted, and the target gets the chosen name and email.
  - The voiceprint count is unchanged.
  - Text replacement for both old names, each scoped to its own person's meetings.
  - `sharedTranscriptMeetings` lists only the transcripts where the two people are different
    speakers.
- **Delete:** an unused person is deleted. A person in use throws `.inUse(meetingCount:)`, and a
  missing person throws `notFound`.
- **Search:** after a rename with replacement and `syncSearchIndex()`, a search for the new title
  word finds the meeting.

## Review outcome

An independent review found these problems, all fixed in this phase with regression tests:

- **Merge replacement could corrupt the target's longer name.** For example, source "Paul" and
  target "Paul Kowalski" with the final name "Paul K." gave "Paul K. Kowalski". Fix: protect
  other people's names that contain the old name. This also covers plain renames: "Paul" →
  "Pablo" no longer rewrites a different person called "Paul Kowalski".
- **A merge could give two people the same email.** `mergePeople` now refuses an email that
  belongs to a third person.
- **The name-collision check compared against the other person's raw name.** It now compares
  against the normalized name.
- **`replacementCounts` used the new name without normalizing it.** It now normalizes it, so the
  counts match the save.
- **A merge of a person into themselves returned silently.** It now applies the choice as an edit.
- **The meeting list was refreshed only when text was replaced.** It is now refreshed after every
  rename and merge, because it shows participant names.

The on-disk search test then found a pre-existing bug in the search sync: a `Person` or `Tag`
change resolved to an unrelated `Meeting` with the same row key, so the person's meetings were
never reindexed. Architecture §3.5 has the details. Fixed by dispatching on the entity name.
