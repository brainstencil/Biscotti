---
status: complete
---

# Implementation Plan: People Management

This plan has four phases. Each one is reviewable on its own and leaves `make test` and `make lint`
green. This file gives the order only. The details are in `functional_spec.md`, `ui_design.md`, and
`architecture.md`.

## Phases

- [x] **Phase 1: DataStore rules, queries, and mutations.**
  - `PersonFieldRules`, `PersonFieldError`, and `NameReplacement` (pure).
  - `DataStore+People.swift`:
    - the use index;
    - `peopleOverview`, `personMeetings`, `replacementCounts`, and `sharedTranscriptMeetings`;
    - `updatePerson`, `mergePeople`, and `deleteUnusedPerson`;
    - `PersonEditError`.
  - Full unit coverage, including a search-reindex test after a rename.
  - *(Functional spec §1, §3. Architecture §3.)*

- [x] **Phase 2: AppCore pass-throughs and PeopleUI models.**
  - `AppCore+People.swift` with `peopleVersion` and `reloadSummaries()` after title-affecting
    changes.
  - The `PeopleUI` target and its test target in `Package.swift`.
  - `PersonEditorModel` (edit, collision, merge draft, debounced counts, error mapping) and
    `PeopleListModel` (filter, delete refused).
  - Model tests against an in-memory `AppCore` fixture.
  - *(Architecture §4, §5.1–5.2. Depends on Phase 1.)*

- [x] **Phase 3: PeopleUI views and the Settings entry point.**
  - `PersonEditorSheet` (edit mode, collision banner, merge mode) and `PeopleListSheet`.
  - `SettingsPeopleSection.swift`, `peopleCount`, the `sectionTitles` insert at index 5 with the
    re-index, and `onOpenMeeting` navigation.
  - Tests for the Settings titles and the count.
  - *(UI design §2–§5. Architecture §5.3, §6.1. Depends on Phase 2.)*

- [x] **Phase 4: Speaker sheet entry point.**
  - The ✎ button and `onEditPerson` in `SpeakerMappingSheet`.
  - `MeetingDetailViewModel.editingPerson`, flush-before-edit, reload-after-save, and
    `onOpenMeeting`.
  - Tests for the detail view model.
  - *(UI design §1. Architecture §6.2. Depends on Phase 3.)*

After Phase 4, follow the feature workflow:

1. UI feedback rounds on the Biscotti Dev build, using a copy of the real library.
2. An independent review.
3. A short demo.
4. The upstream PR, built from a clean branch on `origin/main` without the dev-isolation commits.
