---
status: complete
---

# People Management

Let the user correct the people Biscotti knows about: **rename** a person,
**edit their email**, **delete** a person, and **merge** two records that are the
same human. Today none of this is possible in the app. The only person-related UI
is the per-meeting **Assign Speaker Names** sheet, which can reassign a speaker or
create a new person, but cannot change an existing person. A wrong or duplicate
name (for example an AI-inferred "Steven" that should be "Stephen") stays wrong in
every meeting.

## Why

A `Person` is one shared record. Speaker assignments (JSON on `TranscriptRecord`)
and calendar participants/organizer (relationships on `Meeting`) all point at it by
ID, so fixing the record once fixes the name everywhere. Duplicates arise
naturally: name-only people (no email) are matched by exact name, so spelling
variants, AI guesses, and manual "Add" entries each create a separate record.

## How people are created today

All three paths go through `DataStore.findOrCreatePerson` (match by email, else
by exact name, else create):

1. **Calendar link.** Linking a meeting to an event makes every invitee and the
   organizer a person, with email. These are *invited*, not necessarily present,
   and are stored as meeting participants/organizer, not as speakers. A missing
   display name becomes "Unknown".
2. **AI speaker naming** after transcription. The LLM sees the transcript, the
   invitee list, and voiceprint matches against earlier meetings, and returns
   `speaker | name | email` lines. Voiceprints never assign anyone directly;
   speaker assignments in turn label the voiceprints used for later matching.
3. **Manual "Add"** in the Assign Speaker Names sheet.

In the user's libraries at the time of writing (prod 5 people, dev 11), every
person came from AI naming: no emails, no calendar links, no user-set
assignments. So the expected problem is **duplicates** (spelling variants,
first name vs full name, name-only vs calendar-with-email), not people who do not
exist. **Merge is the primary cleanup tool.** A person who is wrong for one
meeting is fixed by reassigning that speaker, not by delete. Delete is for
records nothing uses any more (left behind by reassignment, "Unknown" invitees,
invented names).

## Decisions

- **Two entry points.**
  - The **Assign Speaker Names** sheet gets edit actions for the assigned person,
    where a wrong name is usually noticed.
  - A **People sheet** opened from a new row in **Settings** lists everyone for
    cleanup without opening a meeting (like the custom vocabulary list).
- **Operations in scope:** rename, edit email, delete, and merge. Merge has no
  separate action: it is offered when a rename or email edit collides with
  another person ("if two entries are the same person, rename one to match the
  other").
- **People sheet shows, per person:** name, email, meeting count, and last-seen
  date. The **person editor** lists the person's meetings (so a lumped-together
  person is visible before a rename) and opens any of them.
- **Name collisions:** renaming a person to a name another person already has
  offers two choices: **merge** the two records, or **pick a different name**.
  The rename does not silently create a duplicate.
- **Merge:** the user picks which name and which email the surviving person
  keeps. If both people are assigned to speakers in the same transcript, the
  merge dialog **warns first** (lists those meetings) and asks to confirm; after
  the merge both speakers point at the one person.
- **Delete: only unused people** (no speaker, participant, or organizer use).
  Anyone still in use must be merged or reassigned first.
- **Summaries and titles: replace, never regenerate.** A rename does not
  regenerate summaries. The editor offers to find and replace the old name in
  the person's meetings' summaries and titles (a checkbox, on by default). If
  the user declines, it warns that those summaries keep the old name.
- **Old names / aliases: not in V1.** After a rename, future AI naming may
  occasionally recreate the old name as a new name-only person (voiceprint
  matches usually carry the new name). The user can merge it. Revisit later.

## Known context (from the codebase)

- `DataStore.findOrCreatePerson` matches by email first (case-insensitive) and
  never overwrites a matched person's name, so renames of people with an email
  survive later calendar syncs and AI naming. Without an email it matches by
  exact, case-sensitive name.
- Search indexes organizer + participant names only. Incremental search sync
  already reindexes a person's meetings when the `Person` changes. Speaker names
  are not indexed.
- Voiceprints live on `TranscriptRecord` and are tagged to people through the
  speaker assignments. A merge must re-point these assignments so voice matching
  keeps working for the surviving person.
- There is no production delete for `Person` (only a test helper).

Email validation, email collisions, and what counts as a "use" are settled in
`functional_spec.md`.
