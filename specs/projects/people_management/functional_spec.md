---
status: complete
---

# Functional Spec: People Management

Rename, edit the email of, merge, and delete the people Biscotti knows about.
Context and the decisions behind this spec are in `project_overview.md`. Screen
layout and visual detail are in `ui_design.md`.

## 1 · Concepts

- **Person** — one shared record (`Person`: id, name, optional email). Every
  reference to a person is by id, so an edit to the record shows everywhere the
  person appears. The person is the only cross-meeting identity in the app.
- **Speaker** — a diarization speaker inside one transcript (Speaker 0, 1, …).
  Speaker numbers are local to a transcript. A speaker shows a name only when it
  is **assigned** to a person.
- **Voiceprint** — a voice embedding for one speaker in one transcript. It is
  not an identity. Voiceprints get their label from the speaker assignment, and
  are used only as evidence for AI speaker naming in later meetings ("this voice
  is close to the person Paul"). A rename or merge therefore needs no voiceprint
  change; a speaker whose voice matches a person but who is not assigned to them
  is not affected by edits to that person.
- **Uses of a person** — the three ways a meeting refers to a person:
  1. **Speaker**: a transcript's speaker assignment points at the person. This
     counts **every transcript version** of the meeting, not only the preferred
     one.
  2. **Attendee**: the person is in the meeting's participants (calendar
     invitees).
  3. **Organizer**: the person is the meeting's organizer.
- **A person's meetings** — the distinct meetings with at least one use. The
  **meeting count** is their number. **Last seen** is the most recent effective
  date (`startDate ?? createdAt`) among them; none when the count is 0.
- **Unused person** — meeting count 0.

## 2 · User journeys

These are the cases the design is checked against.

- **J1 · Fix a spelling.** "Steven" should be "Stephen". From a transcript:
  click the speaker name → Assign Speaker Names → pencil next to Steven → rename.
  Every meeting where a speaker is assigned to that person shows "Stephen".
  With the replace checkbox left on (§3.6), their summaries say "Stephen" too.
- **J2 · Turn a first name into a real person.** Rename "Paul" to "Paul
  Kowalski" and add `paul@acme.com`. A later calendar invite with that email
  matches this person instead of creating a new one; AI voice evidence and the
  picker show the full name and email.
- **J3 · Split a lumped-together person.** AI naming matches name-only people by
  exact name, so two different humans called "Paul" share one record. The person
  editor lists Paul's meetings; the user sees one that is a different Paul, opens
  it, and reassigns that speaker to a new person ("Paul Smith") with the existing
  per-meeting picker. Then renames the remaining Paul. No new split operation.
- **J4 · Merge a duplicate.** Two records exist for one human, for example the
  AI wrote "Stephen" in one meeting and "Steven" in another, or "Paul" next to
  "Paul Kowalski" (AI fell back to the first name after J2, or a calendar invite
  arrived before J2). The user renames one to match the other; the app reports
  the collision and offers to merge (§3.5). Merging is always reached this way:
  *if two entries are the same person, rename one to match the other.* The People
  sheet sorts by name, so such pairs sit next to each other.
- **J5 · Fix one meeting.** The AI assigned the wrong person to a speaker in one
  meeting. Reassign that speaker in the picker (existing behaviour). Do not
  rename the person.
- **J6 · Clean up leftovers.** Reassignments, nameless calendar invitees
  ("Unknown"), and invented names leave people in no meetings. The People sheet
  shows them with a count of 0 and the user deletes them.

## 3 · Operations

### 3.1 Rename

- Changes the person's name everywhere it is shown: transcript speaker labels,
  the speaker sheet, the people picker, attendee lists, search results, the MCP
  server, and CSV export.
- Summaries and titles are stored text, so the old name stays in them. The
  editor offers to replace it in the person's meetings (§3.6). A rename never
  regenerates a summary.
- Leading and trailing whitespace is trimmed. Internal whitespace runs collapse
  to one space.
- The name must not be empty and must be at most 120 characters. AI speaker naming
  has no length cap, so an existing longer name must be shortened before it can be
  saved.
- Saving the unchanged name is a no-op.
- A change of case only ("steven" → "Steven") is a normal rename.
- If the new name matches **another** person's name (case-insensitive, after
  normalization), this is a **name collision** (§3.5).

### 3.2 Edit email

- The email is optional. Clearing the field removes the email.
- Trimmed and lowercased before saving.
- Validation is minimal: exactly one `@`, a non-empty part on each side, and no
  whitespace. Invalid input shows an inline error and is not saved.
- If the new email matches **another** person's email (case-insensitive), this is
  an **email collision**, handled like a name collision (§3.5). Email is the key
  `findOrCreatePerson` matches on, so two people with one email would make future
  calendar and AI matching pick one of them arbitrarily.
- Name and email are edited together and saved as one change.

### 3.3 Merge

Combines two person records that are the same human into one. Reached only from
a collision (§3.5); there is no separate merge action.

- The person being edited is the **source**; the person it collides with is the
  **target**. The target record survives; the source record is removed.
- The merge dialog shows both people and lets the user choose:
  - **Name**: the name the user typed, the source's, or the target's. Defaults to
    the typed name.
  - **Email**: the typed email, the source's, the target's, or none. Defaults to
    the typed email if one was entered, else the target's, else the source's.
  Choices that are identical are shown once.
- On confirm, in one save:
  - Every speaker assignment that points at the source, in every transcript
    version, points at the target. Each assignment keeps its `userSet` flag.
  - Every meeting with the source as an attendee has the target instead. A
    meeting that already has both keeps the target once.
  - Every meeting with the source as organizer has the target as organizer.
  - The target gets the chosen name and email.
  - The source record is deleted.
- **Same-transcript warning.** If any transcript version assigns the source and
  the target to *different* speakers, the dialog lists those meetings (title and
  date) above the Merge button with the message that both speakers will show the
  merged name. The user must still press Merge to continue; nothing extra to
  tick.
- If the chosen name differs from the source's or the target's old name, the
  dialog offers the summary and title replacement (§3.6) for each old name, in
  that person's meetings. It is part of the same save.
- No voiceprint rows change (§1). Both people's voiceprints count as the
  surviving person for later AI naming.
- Merge is not undoable in V1. The dialog says so.

### 3.4 Delete

- Available **only for unused people** (meeting count 0).
- For a person in use, the delete action is disabled and explains why: "In use
  in N meetings. Reassign or merge to remove."
- No confirmation dialog for an unused person (nothing references it).
- If the person gained a use between display and the delete (for example, AI
  naming finished in the background), the delete is refused, the list refreshes,
  and the row shows the in-use state.

### 3.5 Collisions (rename or email)

When a save would give a person the same name or email as another person, the
save is held and the editor shows:

> **"Stephen" is already a person.** (or "… already has this email.")
> [Merge with Stephen…] [Keep editing]

- **Merge with …** opens the merge dialog (§3.3).
- **Keep editing** returns to the editor with the typed value intact so the user
  can differentiate it (for example "Paul Smith").
- If the name and the email collide with **different** people, the editor
  reports the name collision first. After that is resolved, saving again surfaces
  the email collision.

### 3.6 Replace the old name in summaries and titles

The AI writes names into a meeting's summary and, for an untitled recording,
its title. These are stored text, so they keep the old name after a rename or
merge. The app does not regenerate them. Instead it asks.

- **When it is offered.** The name changed, and at least one of the person's
  meetings (§1) has a summary or title that contains the old name.
- **How it is asked.** A checkbox under the Name field in the editor (§5), and
  in the merge dialog (§3.3):
  > ☑ Also change "Steven" to "Stephen" in 3 summaries and 1 title
  
  It is on by default. When the user turns it off, the caption reads: "Summaries
  and titles that mention "Steven" will keep the old name." The count updates as
  the user types the new name.
- **What is replaced.** Whole-word, case-sensitive occurrences of the exact old
  name. A possessive ("Steven's") matches. An occurrence that is already part of
  the new name is left alone, so renaming "Paul" to "Paul Kowalski" does not
  turn "Paul Kowalski" into "Paul Kowalski Kowalski".
- **What is not replaced.**
  - Text in meetings that are not the person's meetings.
  - Partial names: renaming "Paul Kowalski" does not touch a summary that says
    only "Paul".
  - The user's own notes, and calendar event data.
- **Where.** Each meeting's summary (AI-written or user-edited) and title. The
  `editedSummary` and `editedTitle` flags do not change: this is a correction,
  not new authorship.
- The replacement is part of the same save as the rename. It is not undoable in
  V1.

## 4 · Entry points

### 4.1 Assign Speaker Names sheet

- Each speaker row whose speaker has an assigned person gets an **Edit** button
  (pencil) after the person pill. Unassigned rows have none.
- Edit opens the **person editor** (§5) for that person.
- After a save or merge, the sheet and the meeting detail behind it refresh, so
  transcript labels show the new name at once.
- The people picker popover is unchanged, except that it lists the new name and
  no longer lists a merged-away source.

### 4.2 People sheet (Settings)

- Settings gets a **People** section with one row: "People", the caption "Rename,
  merge, and clean up the people Biscotti has identified.", and a button
  "Manage (N)" where N is the number of people. The button opens the People sheet.
- The People sheet lists every person, sorted by name (case-insensitive), so
  likely duplicates sit next to each other.
- A filter field at the top matches name or email (case-insensitive substring).
- Each row shows the name, the email (if any), the meeting count, and last seen.
- Each row has actions:
  - **Edit…** — opens the person editor (§5).
  - **Delete** — per §3.4.
- Empty state (no people): "No people yet. Biscotti adds people when it
  identifies speakers or when a meeting is linked to a calendar event."
- After any change, the list (names, counts, last seen) refreshes.

## 5 · Person editor

A sheet shared by both entry points:

- Fields: **Name** (required), **Email** (optional).
- Under Name, the summary and title replacement checkbox when it applies (§3.6).
- **Meetings list**: every meeting of this person (§1), newest first, each with
  title, date, and how the person appears (speaker / attendee / organizer).
  Heading: "Changes apply to these N meetings." Clicking a meeting closes the
  editor (and the sheet it came from) and opens that meeting. This is how the
  user spots a lumped-together person (J3) before renaming.
- Buttons: **Cancel**, **Save** (default; disabled while the name is empty or
  nothing has changed).
- Inline validation messages for an empty or too-long name and an invalid email.
- Collision handling per §3.5.

## 6 · Effects on other features

- **Summaries and titles.** Updated only by the optional replacement in §3.6.
  Never regenerated by a rename or merge.
- **Search.** Attendee and organizer names and meeting titles are indexed, so a
  rename, merge, or title replacement reindexes the affected meetings (existing
  incremental sync through the `Person` / `Meeting` history). Speaker names are
  not indexed; no change.
- **AI speaker naming.** Unchanged. It may create a new person with an old or
  short name later (no aliases in V1). The user merges it (J4).
- **Calendar re-link.** Matching by email means a renamed person with an email
  keeps the new name when an event is linked again. A name-only person can be
  re-created under the calendar's name; the user merges it.
- **CSV export, MCP server.** Read names at request time; they show the new name
  with no change.

## 7 · Edge cases

- **Concurrent AI naming.** If AI naming assigns a speaker to a person that a
  merge removes in the same moment, that assignment can dangle and the speaker
  shows as unassigned (dangling ids are already dropped on read). Rare; the user
  can reassign. Not handled specially in V1.
- **Editing a person that no longer exists** (merged or deleted from the other
  entry point while the editor was open): Save fails with "This person no longer
  exists." and the editor closes.
- **Duplicate pairs with identical names** already in the library (from before
  this feature): saving either one with its current name is a no-op, so no
  collision appears. Renaming one to anything matching the other (including
  re-typing the same name with different case) triggers the collision flow.
  **Open for review:** whether the editor should instead flag an existing
  same-name pair as soon as it opens.

## 8 · Out of scope (V1)

- A separate merge action (merge is reached through a collision).
- Aliases / remembering old names for future AI naming.
- Regenerating summaries after a rename, and any summary rewrite beyond the
  exact-name replacement in §3.6.
- Undo for merge or delete.
- Bulk actions (multi-select merge, "delete all unused").
- Avatars, notes, or other new person fields.
- Automatic duplicate detection or merge suggestions.
- A People destination in the sidebar.
