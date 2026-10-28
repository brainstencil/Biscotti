---
status: complete
---

# Phase 2: AppCore Pass-Throughs and PeopleUI Models

## Steps

1. Add `AppCore.peopleVersion`, a stored property in the class body.
2. Add `AppCore+People.swift` with pass-throughs to the `DataStore` queries and mutations. After a
   rename or merge, it bumps `peopleVersion` and calls `reloadSummaries()`. After a delete, it
   bumps `peopleVersion` only.
3. Add the `PeopleUI` target (`AppCore`, `AppLinks`, `DataStore`, `DesignSystem`, `Formatting`)
   and the `PeopleUITests` target to `Package.swift`.
4. Add `PeopleCopy`, which holds every user-facing string from ui_design.md §5.
5. Add `PersonEditorModel`:
   - load, with field validation and `canSave`;
   - debounced replacement counts (the delay can be injected for tests);
   - save, with error mapping to a collision, a missing person, or a generic failure;
   - keep-editing;
   - merge mode: `beginMerge`, `chooseMergeName`, `confirmMerge`, `cancelMerge`.
6. Add `MergeDraft`, with pure option and default rules and the merge copy.
7. Add `PeopleListModel`: filter, delete with reload, and the editor lifecycle.

## Tests

`Tests/PeopleUITests/PeopleModelTests.swift` covers:

- copy and plurals;
- the `MergeDraft` options, defaults, and choice;
- the editor: load and validation, replacement on and off, name collision through to merge, an
  email collision cleared by an edit, and a missing person;
- the list: filter and delete, a stale delete refused, and a reload after the editor closes.
