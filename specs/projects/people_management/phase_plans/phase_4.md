---
status: complete
---

# Phase 4: Speaker Sheet Entry Point

## Steps

1. In `SpeakerMappingSheet`, add `onEditPerson` and a pencil button after the pill on assigned rows,
   with the tooltip `Edit <name>…`.
2. In `MeetingDetailViewModel`, add:
   - `editingPerson`;
   - `editPerson(_:)`, which saves pending summary and title edits first;
   - `peopleVersion`;
   - `reloadAfterPeopleChange()`;
   - `openMeetingFromPersonEditor(_:)`. For the current meeting it switches to the Transcript tab.
3. In `MeetingDetailView`, present `PersonEditorSheet` as a sheet over the speaker sheet, and
   reload on `peopleVersion` changes.

## Tests

`Tests/MeetingDetailUITests/PersonEditingTests.swift` covers:

- a pending summary edit is saved before the editor opens;
- after a rename, the transcript labels, the sheet rows, the summary, and the title all reload;
- opening the current meeting closes both sheets and selects the Transcript tab.
