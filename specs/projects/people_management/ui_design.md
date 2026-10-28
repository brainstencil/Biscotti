---
status: complete
---

# UI Design: People Management

Four surfaces:

1. An edit button in the Assign Speaker Names sheet.
2. A People row in Settings.
3. The People sheet.
4. The person editor sheet, which also holds the merge step.

All four use existing `DesignSystem` tokens and copy patterns from `SpeakerMappingSheet`,
`SettingsVocabularySection`, and `VocabularyListSheet`. The rules are in `functional_spec.md`;
this file covers layout and copy only.

## 1. Assign Speaker Names sheet: edit button

```
┌─ Assign Speaker Names ───────────────────────────────────┐
│ Match each detected speaker to a person.                 │
│                                                          │
│ ● Speaker 0   [ Unassigned  ⌃⌄ ]                          │
│ ● Speaker 1   [ Steven  ⌃⌄ ]  ✎                           │
│ ● Speaker 2   [ Paul  ⌃⌄ ]  ✎                             │
│ ──────────────────────────────────────────────────────── │
│                                              [ Done ]    │
└──────────────────────────────────────────────────────────┘
```

- **The ✎ button** is a plain `Button` with the SF Symbol `pencil`, 12pt, `.inkSecondary`. It sits
  directly after the pill, inside the row's `HStack`, and only on rows that have an assigned person.
  Tooltip (`.help`): `Edit Steven…`.
- Clicking it opens the person editor (§4) as a sheet over this sheet. Done on the editor's parent
  stays usable after the editor closes.
- After a save or merge, the rows, the picker list, and the transcript behind the sheet show the new
  name. The sheet does not scroll or lose its focused row.

## 2. Settings: People section

A new section, **People**, goes directly after **Custom Vocabulary** and before **Import/Export**.
It has one row and the same shape as the `Vocabulary List` row:

```
┌─ People ───────────────────────────────────────────────────────┐
│ People                                          [ Manage (16) ] │
│   Rename, merge, and clean up the people Biscotti has          │
│   identified.                                                   │
└─────────────────────────────────────────────────────────────────┘
```

- Title, `Tokens.metadataFont` / `Tokens.secondaryText` caption, `Spacer`, and a trailing
  `Button("Manage (N)")` with `.buttonStyle(.bordered)` and `.controlSize(.small)`.
- `N` is the number of people. It reloads when the People sheet closes.
- **Index gotcha.** `SettingsView.sectionTitles` is positional. "People" goes in at index 5, so
  Import/Export moves to 6 and Calendars to 7. Every `sectionTitles[N]` reference and every
  Settings test that checks titles must be updated.

## 3. People sheet

Opened by **Manage (N)**. Same frame as `VocabularyListSheet`: `Tokens.spacingLG` padding, width
560 (a little wider to fit the meta column).

```
┌──────────────────────────────────────────────────────────────┐
│  SETTINGS                                                     │
│  People                                                       │
│  Everyone Biscotti has identified in your meetings.           │
│                                                               │
│  ┌─────────────────────────────────────────────┐              │
│  │ 🔍 Filter by name or email…                 │              │
│  └─────────────────────────────────────────────┘              │
│  ┌──────────────────────────────────────────────────────┐     │
│  │ Paul                     12 meetings · Oct 26  ✎  🗑 │     │
│  │ Paul Kowalski            1 meeting · Oct 3     ✎  🗑 │     │
│  │ paul@acme.com                                        │     │
│  │ Stephen                  3 meetings · Sep 30   ✎  🗑 │     │
│  │ Steven                   40 meetings · Oct 26  ✎  🗑 │     │
│  │ Unknown                  Not in any meetings   ✎  🗑 │     │
│  │ …                                                    │ ← scrolls
│  └──────────────────────────────────────────────────────┘     │
│  ───────────────────────────────────────────────────────────  │
│                                                   [ Done ]    │
└──────────────────────────────────────────────────────────────┘
```

- **Header:** kicker `SETTINGS` (`.kicker()`, `.sage`), serif 27 title `People`, 13pt `.inkSecondary`
  subtitle `Everyone Biscotti has identified in your meetings.`
- **Filter field:** `TextField` with `.roundedBorder` and placeholder `Filter by name or email…`.
  It has focus when the sheet opens. Case-insensitive substring match on name or email. When nothing
  matches, the list area shows `No people match "<text>".`
- **List:** `ScrollView` + `LazyVStack` with a `Divider` between rows. Maximum height 400, then it
  scrolls. Sorted by name, case-insensitive.
- **Row:**
  - Left: name at 14pt `.ink`. If the person has an email, it shows below the name at
    `.caption` `.inkSecondary`.
  - Right: meta text at `Tokens.metadataFont` `.inkSecondary`: `12 meetings · Oct 26`, `1 meeting ·
    Oct 3`, or `Not in any meetings`. The date is `TimeFormatting.shortDate`.
  - Then two plain icon buttons:
    - `pencil`, tooltip `Edit…`. Opens the person editor.
    - `trash`. When enabled it uses `.signalRedText`, with the tooltip `Delete`. When the person is
      in use it is disabled at `.inkTertiary`, with the tooltip `In use in 12 meetings. Reassign or
      merge to remove.`
  - Double-clicking the row also opens the editor.
- **Delete:** no confirmation. The row disappears. If the store refuses because the person is now
  in use, the list reloads and the row shows its new count and a disabled trash button.
- **Empty state** (no people at all): `No people yet. Biscotti adds people when it identifies
  speakers or when a meeting is linked to a calendar event.`
- **Footer:** `Divider()` and a right-aligned `Done` (`.keyboardShortcut(.defaultAction)`). There is
  no Cancel, because each action saves at once.
- The list reloads after the editor closes with a change.

## 4. Person editor sheet

One sheet, used from both entry points. Width 520. It has two modes: **edit**, and **merge**, which
it switches to from a collision. Both modes use the same sheet, so no third sheet stacks up.

### 4.1 Edit mode

```
┌──────────────────────────────────────────────────────────┐
│  PERSON                                                   │
│  Steven                                                   │
│                                                           │
│  Name   ┌───────────────────────────────────────────┐     │
│         │ Stephen                                   │     │
│         └───────────────────────────────────────────┘     │
│         ☑ Also change "Steven" to "Stephen" in 3          │
│           summaries and 1 title                           │
│  Email  ┌───────────────────────────────────────────┐     │
│         │ Optional                                  │     │
│         └───────────────────────────────────────────┘     │
│                                                           │
│  CHANGES APPLY TO THESE 4 MEETINGS                        │
│  ┌───────────────────────────────────────────────────┐    │
│  │ Aerospace Branding and Web Strategy  Oct 26  Speaker › │
│  │ Weekly Sync                Oct 19  Speaker · Attendee › │
│  │ Kickoff                     Oct 2  Organizer        › │
│  │ …                                                 │ ← scrolls
│  └───────────────────────────────────────────────────┘    │
│  ───────────────────────────────────────────────────────  │
│                                  [ Cancel ]  [  Save  ]   │
└──────────────────────────────────────────────────────────┘
```

- **Header:** kicker `PERSON` (`.sage`), serif 27 title with the person's **saved** name. The title
  does not change while the user types.
- **Fields:** a two-column `Grid`. Labels are right-aligned at 13pt `.inkSecondary`. Fields are
  `.roundedBorder`. The Email placeholder is `Optional`. Name has focus on open, with all text
  selected.
- **Inline messages** sit under their field at `Tokens.metadataFont` `.signalRedText`. They update
  as the user types:
  - `Enter a name.`
  - `Keep names under 120 characters.`
  - `Enter a valid email address, or leave it empty.`
- **Replace checkbox** (§3.6 of the functional spec): a `Toggle` with `.checkbox` style, under
  Name. It is shown only when the name changed and the count is above 0. The label reads `Also
  change "Steven" to "Stephen" in 3 summaries and 1 title`. Drop the part with a count of 0, and use
  singular or plural to match the count. When the box is off, a caption appears below it at
  `Tokens.metadataFont` `.inkSecondary`: `Summaries and titles that mention "Steven" will keep the
  old name.` The count updates about 250 ms after the user stops typing.
- **Meetings list:**
  - Heading: kicker style, `CHANGES APPLY TO THESE N MEETINGS` (or `THIS MEETING` when N is 1).
  - Rows: title at 13pt `.ink` (one line, truncated in the middle), the date at
    `Tokens.metadataFont` `.inkSecondary`, the roles joined with ` · `, and a `chevron.right`.
  - Each row is a plain button that highlights on hover. Clicking a row closes the editor and the
    sheet that opened it, then opens that meeting on its Transcript tab.
  - Maximum height 220, then the list scrolls.
  - With 0 meetings, show `Not in any meetings.` in place of the list.
- **Footer:** `Cancel` (`.cancelAction`) and `Save` (`.defaultAction`). Save is disabled while
  either field shows an error, or while nothing has changed.
- **After Save** the sheet closes. There is no confirmation alert, because the summary and title
  choice was made before saving.
- **Person removed elsewhere:** if the person was deleted or merged away while the editor was open,
  Save shows `This person no longer exists.` in red above the footer. Save then becomes a `Close`
  button.

### 4.2 Collision banner

When Save finds a collision, the sheet stays in edit mode and shows a banner between the fields and
the meetings list. The banner is a `RoundedRectangle` with `Color.neutralChip` fill and 12pt
padding:

```
┌───────────────────────────────────────────────────────┐
│ ⚠︎ "Stephen" is already a person.                      │
│   If they're the same person, merge them. Otherwise,  │
│   choose a different name.                            │
│                [ Keep Editing ]  [ Merge with Stephen… ]│
└───────────────────────────────────────────────────────┘
```

- Email form: `paul@acme.com already belongs to Paul Kowalski.`
- `Keep Editing` hides the banner and puts focus back in the field that collided, with its text
  kept. Editing that field also hides the banner.
- `Merge with Stephen…` switches the sheet to merge mode.

### 4.3 Merge mode

```
┌──────────────────────────────────────────────────────────┐
│  MERGE PEOPLE                                             │
│  Steven → Stephen                                         │
│  Steven's 40 meetings move to Stephen. Steven is removed. │
│                                                           │
│  Name    ◉ Stephen        (typed)                         │
│          ○ Steven                                         │
│  Email   ◉ stephen@acme.com                               │
│          ○ None                                           │
│                                                           │
│  ☑ Also change "Steven" to "Stephen" in 12 summaries      │
│                                                           │
│  ┌─ ⚠︎ Both are speakers in 2 meetings ──────────────────┐ │
│  │ Both speakers will show as Stephen in:                │ │
│  │ Weekly Sync · Oct 19                                  │ │
│  │ Kickoff · Oct 2                                       │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                           │
│  Merging can't be undone.                                 │
│  ───────────────────────────────────────────────────────  │
│                                   [ Back ]  [  Merge  ]   │
└──────────────────────────────────────────────────────────┘
```

- **Header:** kicker `MERGE PEOPLE`, serif 27 `Source → Target`, and a 13pt subtitle:
  `<source>'s N meetings move to <target>. <source> is removed.`
- **Name and Email choices:** each is a `Picker` with `.radioGroup` style. Identical options appear
  once. A choice that came from the typed value is marked `(typed)` in `.inkTertiary`. The Email
  options include `None`. Defaults are as in functional spec §3.3.
- **Replace checkboxes:** one per old name that differs from the chosen name, for example `Also
  change "Steven" to "Stephen" in 12 summaries` and `Also change "Stephen" to …`. The counts are
  scoped to that old name's own person's meetings. Each checkbox uses the same rules and
  off-caption as edit mode.
- **Same-transcript warning:** shown only when it applies. It is a box with `Tokens.warningBackground` fill and a `.warningOchre` triangle, a
  heading, and the list of meetings (title · date), with a maximum height of 120 before it scrolls.
  No extra checkbox is needed to continue.
- `Merging can't be undone.` at `Tokens.metadataFont` `.inkSecondary`, above the footer.
- **Footer:** `Back` returns to edit mode with the typed values kept. `Merge` is the default
  action. When the merge succeeds, the sheet closes.

## 5. Copy reference

| Where | Text |
|---|---|
| Speaker row button tooltip | `Edit <name>…` |
| Settings row | `People` / `Rename, merge, and clean up the people Biscotti has identified.` / `Manage (N)` |
| People sheet subtitle | `Everyone Biscotti has identified in your meetings.` |
| People sheet empty | `No people yet. Biscotti adds people when it identifies speakers or when a meeting is linked to a calendar event.` |
| Filter, no match | `No people match "<text>".` |
| Row meta | `N meetings · <date>` / `1 meeting · <date>` / `Not in any meetings` |
| Disabled delete tooltip | `In use in N meetings. Reassign or merge to remove.` (`1 meeting` when N is 1) |
| Name errors | `Enter a name.` / `Keep names under 120 characters.` |
| Email error | `Enter a valid email address, or leave it empty.` |
| Name collision | `"<name>" is already a person.` |
| Email collision | `<email> already belongs to <name>.` |
| Collision help | `If they're the same person, merge them. Otherwise, choose a different name.` |
| Replace on | `Also change "<old>" to "<new>" in N summaries and M titles` |
| Replace off | `Summaries and titles that mention "<old>" will keep the old name.` |
| Missing person | `This person no longer exists.` |
| Merge irreversible | `Merging can't be undone.` |

## 6. Rejected alternatives

- **A confirmation alert after a rename** asking about summaries. Rejected: the checkbox shows the
  choice and its effect before saving, and avoids a second step.
- **A separate merge sheet stacked on the editor.** Rejected: from the speaker sheet that would be
  three sheets deep. Switching the editor's mode keeps it at two.
- **Inline rename in the People list (as in the vocabulary list).** Rejected: a rename needs the
  meetings list, the replace choice, and collision handling, and that does not fit in a row.
- **A People destination in the sidebar.** Out of scope for V1 (functional spec §8).
