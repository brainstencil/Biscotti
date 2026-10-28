---
status: complete
---

# Phase 3: PeopleUI Views and the Settings Entry Point

## Steps

1. Add `PersonEditorSheet`, which contains:
   - the header;
   - the Name and Email grid, with inline errors and the replace checkbox;
   - the collision banner;
   - the meetings list, where each row opens that meeting;
   - the footer, which switches to `Close` when the person is missing.
2. Add `MergeModeView`, which contains:
   - the Name and Email radio groups;
   - one replace checkbox per old name;
   - the same-transcript warning;
   - the note that merging is irreversible;
   - the Back and Merge buttons.
3. Add `PeopleListSheet`: the filter field, the rows with edit and delete buttons, the empty and
   no-match states, and the editor shown as a nested sheet.
4. Add `SettingsPeopleSection.swift` with the People row and its sheet. Opening a meeting closes
   the sheet and calls `AppCore.apply(.meeting(id:target: .tab(.transcript)))`.
5. Insert `"People"` at `sectionTitles` index 5, and re-index Import/Export (6) and Calendars (7).
6. Add `SettingsViewModel.peopleCount`, with `reloadPeopleCount()` in
   `SettingsViewModel+People.swift`.

## Tests

- `SettingsLayoutTests` checks the updated section titles.
- `SettingsPeopleCountTests` checks the count.
- The views are checked by building them, and visually in the Dev-build UI round.
