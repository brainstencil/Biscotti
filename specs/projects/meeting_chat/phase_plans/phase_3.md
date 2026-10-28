---
status: complete
---

# Phase 3: The MeetingChat target and ChatContextBuilder

## Overview

Creates the `MeetingChat` module and its pure context code ([chat_context](../components/chat_context.md)): timestamped evidence lines from a live snapshot, a draft or a saved transcript; the system prompt with the rules and the meeting record; fitting a long meeting into the context by dropping earlier turns and then selecting passages; and parsing an answer's Markdown into blocks with checked time citations. No I/O: the only outside call is the injected token counter. `MeetingChatService` (phase 4) and the UI (phase 8) build on this.

This phase relies on `ChatBasis` only, in the shared file `Packages/BiscottiKit/Sources/DataStore/ChatBasis.swift` (byte for byte as `agent-env.md` gives it). The rest of the chat storage is phase 1's.

## Steps

1. **Shared file.** Create `Packages/BiscottiKit/Sources/DataStore/ChatBasis.swift` with the exact content from `agent-env.md`.

2. **Package.** In `Packages/BiscottiKit/Package.swift`, add the `MeetingChat` library product and two targets, at the end of their lists to keep merges with phases 1 and 2 simple:
   - `MeetingChat`: depends on `DataStore`, `Formatting`, `LiveTranscriptModel` (Transcription) and `LocalLLM`. Phase 4 adds `Intelligence` and `LiveTranscriptionService` when the service needs them.
   - `MeetingChatTests`: depends on `MeetingChat`, `DataStore`, `LiveTranscriptModel` and `LocalLLM`. Phase 4 adds `BiscottiTestSupport`.

3. **`ChatTypes.swift`**: the public value types `ChatTranscript` (`.live`, `.draft`, `.saved`), `ChatMeetingRecord`, `ChatTurn`, `ChatEvidenceLine` and `ChatPrompt` (internal memberwise init), and `ChatPromptError.tooLong`, as the component doc gives them.

4. **`ChatEvidence.swift`**:
   - `lines(for:)`: live and draft rows become one line each ("You" for `.mic`, "Others" for `.system`, no speaker for `.mixed`, which names none); `text` is the settled text and `unsettled` the tail, both trimmed, with line breaks folded to spaces so one line stays one entry. Saved segments resolve the speaker with `speakerName(forID:)`, then `speakerLabel`, and merge with the previous line while the speaker is the same, the pause is under 3 s and the merged line spans at most 60 s.
   - `gaps(for:)`: the snapshot's gaps that may have held sound (`!isSilent`), merged across tracks where they touch or overlap, keeping stretches of at least 1 s. Saved transcripts have none.
   - `format(_:)`: `TimeFormatting.formatPlaybackTime` (floored `m:ss` / `h:mm:ss`).
   - Internal `entries(for:)`: lines and gaps in one time-ordered list of `ChatEvidenceEntry` (start, formatted text, the line if any), formatted `[4:05] Others: text {tail}` and `[4:05–4:20 not transcribed]`.

5. **`ChatPrompts.swift`**:
   - `rules`: the verbatim rules text; `unsettledRule` is the braces rule and `partialRule` the long-meeting rule.
   - `system(isPartial:isLive:)`: the rules, without the braces rule unless the transcript is live (only live snapshots carry a tail), plus `partialRule` when partial.
   - `meetingBlock(_:timeZone:)`: `Title:`, `Date:` ("Tuesday, 27 October 2026, 6:04 PM", `en_US_POSIX`), `Invited (not proof of who spoke):` when there are invitees, and `Transcript:` ("live, recording in progress, through m:ss" from `transcribedThrough`, "draft, made during the recording", or "final").
   - `systemMessage(rules:meeting:transcript:notes:)`: rules, `<meeting>`, `<transcript>`, then `<notes>` only when the notes are not blank.

6. **`ChatSelection.swift`**: `ChatSelection.select(entries:question:isLive:transcriptBudget:)` returns a value holding the windows and which are kept.
   - Windows of about 60 s; always kept: those starting in the first 120 s of the transcript and, live, those reaching into its last 300 s.
   - `queryTerms(in:)`: lowercased letter-and-digit words of at least 3 characters minus `stopwords` (about 150 English words).
   - Score `ln(1 + N / (1 + df))` per distinct query term in a window; ties go to the later window. Optional windows are added in score order while the kept text's estimate (characters ÷ 3.5) fits 90% of the budget.
   - `transcript`: kept windows in time order, with `[a–b not included]` between kept windows that are not adjacent and after the last kept window when the rest was dropped. `evidenceTimes`: the kept lines' starts.
   - `mutating func dropLowestScoringOptional() -> Bool`.

7. **`ChatPromptBuilder.swift`**: `build(record:earlierTurns:question:count:)`:
   - Turns: blank answers left out, then the newest `maxEarlierTurns` (6), as alternating user and assistant messages before the question.
   - Fit: full prompt; then drop the oldest turns down to two, recounting each time; then selection, with the budget `maxContext − answerReserve −` the count of the prompt with an empty transcript; recount and drop the lowest-scoring optional window up to 5 times, then throw `tooLong`.
   - `contextSize`: `promptTokens + answerReserve`, rounded up to a multiple of 4,096, capped at `maxContext`. Options `GenerationOptions(maxTokens: 1024, temperature: 0.3, thinking: .off)`. Basis `.live(through: transcribedThrough)`, `.draft` or `.transcript(id:)`.

8. **`ChatAnswerParser.swift`**:
   - `ChatBlock` and `ChatTimeAttribute` as the component doc gives them.
   - `blocks(_:evidenceTimes:)`: one linear pass over the lines into paragraphs (consecutive plain lines joined with line breaks), bullets (`- `/`* `, level 1 + leading spaces ÷ 2), numbered items (`N. `/`N) `) and headings (`#` to `###`). A marker alone at the end of a streaming answer already counts as its block. Inline Markdown with `.inlineOnlyPreservingWhitespace` and `.returnPartiallyParsedIfPossible`, plain text if parsing throws.
   - Citations: `[m:ss]`, `[h:mm:ss]` and ranges `[12:34–13:10]` lose their brackets; the time (or range) carries `ChatTimeAttribute` set to the nearest evidence time when that is within 15 s, found by binary search. Other attributes of the run, such as bold, are kept.

## Tests

`MeetingChatTests/ChatEvidenceTests.swift`:
- `liveRowsBecomeLines`: mic rows are "You", system rows "Others", tails go to `unsettled`, and the formatted line puts the tail in braces.
- `mixedRowsNameNoSpeaker`: a `.mixed` row formats as `[0:05] text`.
- `savedSegmentsMergeSameSpeaker`: segments 1 s apart from one speaker merge; a 4 s pause or a change of speaker starts a new line; a merged line never spans more than 60 s.
- `speakerNamesPreferAssignments`: an assigned person's name replaces "Speaker 2".
- `timesFormat`: 65 → "1:05", 3729 → "1:02:09", 59.9 → "0:59".
- `gapsBecomeLines`: a gap is listed as `[4:05–4:20 not transcribed]` in time order; overlapping gaps on two tracks merge; silent gaps are left out.

`MeetingChatTests/ChatPromptBuilderTests.swift` (counter: characters ÷ 4):
- `orderIsRulesMeetingTranscriptNotes`: the system message contains, in order, the rules, `<meeting>`, `<transcript>` and `<notes>`.
- `liveTranscriptLine`: the meeting block says "live, recording in progress, through 0:46"; the basis is `.live(through: 46)` and the braces rule is present.
- `savedTranscriptLineAndBasis`: a saved transcript reads "final", has basis `.transcript(id:)`, and no braces rule; a draft reads "draft, made during the recording" with basis `.draft`.
- `emptyNotesAndInviteesLeftOut`.
- `earlierTurnsAlternate`: two earlier turns produce user, assistant, user, assistant, then the question; failed (blank) answers are skipped; only the newest six turns are kept.
- `optionsAreFixed`: max tokens 1024, temperature 0.3, thinking off.
- `contextRoundsTo4096`: a 9,000-token prompt gives a context of 12,288; two consecutive questions in a thread give the same size.
- `longMeetingDropsTurnsFirst`: an over-long prompt drops earlier turns before selecting passages.
- `selectionKeepsStartAndEnd`: in a three-hour live transcript, the first 120 s and the last 300 s are always kept.
- `selectionPrefersMatchingWindows`: the window containing "battery" is kept for "What about battery life?" when most windows are dropped.
- `selectionMarksOmissions`: dropped stretches appear as `[a–b not included]` and `isPartial` is true, with the extra rule present.
- `tooLongThrows`: a counter that always reports more than the maximum makes `build` throw `tooLong`.
- `countErrorsPropagate`: an error thrown by the counter reaches the caller.
- `evidenceTimesMatchLinesGiven`: after selection, `evidenceTimes` contains only the kept lines' starts.

`MeetingChatTests/ChatSelectionTests.swift`:
- `queryTermsDropStopwordsAndShortWords`.
- `tiesGoToLaterWindow`.

`MeetingChatTests/ChatAnswerParserTests.swift`:
- `paragraphsAndLists`: blank lines split paragraphs; `- ` and `1. ` lines become bullets and numbered items; indented bullets get level 2; headings lose their hashes.
- `inlineMarkdown`: bold and italic runs are kept.
- `unclosedBoldDoesNotFail`: "Some **bold" parses as text.
- `validCitationBecomesTime`: "[0:21]" with evidence at 0:20 becomes "0:21" carrying the attribute value 20.
- `farCitationStaysPlain`: "[9:00]" with no evidence within 15 s becomes plain "9:00" with no attribute.
- `hourCitation`: "[1:02:09]" parses as 3729 s.
- `rangeCitationUsesStart`: "[12:34–13:10]" links to the evidence nearest 12:34.
- `boldCitationKeepsBold`: a citation inside bold text keeps its bold run.
- `streamingMarkerStartsBlock`: a trailing "- " line is an empty bullet, not a paragraph.
