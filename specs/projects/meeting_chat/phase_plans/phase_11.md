---
status: complete
---

# Phase 11: Backlog

## Overview

The Backlog phase decides every open item with the user and closes or dismisses each one. The interview on 29 October 2026 decided 18 items. B1 to B3 are in `backlog.md`. B4 to B8 were folded into the interview from earlier phases' open questions (phase 6's proposals, phase 10's findings and open questions); the phase adds no items to `backlog.md`, so this plan is their record.

The phase ran in three runs:

- **Run 1**, commit f514822 ("Answer during recordings on every Mac and remove the live hold"): B4 and B5.
- **Run 2**, commit 69f53a5 ("Catch up the live transcript from 0:00 when it starts mid-recording"): B1 and B2.
- **Run 3**, this plan's steps, the last run: B3, B6a, B6b, B6c, B6e-1, B6e-4 and B6e-5, and the phase's close-out.

Nothing in `Packages/Transcription`, `AudioCapture`, `LocalLLM` or `MCPServer` changes, so no manual tests are reset.

## Decisions

| Item | Decision | Why | Where it landed |
|---|---|---|---|
| B1 | Fix: turning the live transcript on mid-recording, from chat or from Settings, catches up from the start of the recording. The live transcript reads the recording files from 0:00 and feeds them to its existing catch-up. | The user: when you turn on chat, you want the whole transcript. | Run 2, 69f53a5 |
| B2 | Fix with B1: what the drawer shows while a mid-recording start catches up. | Coupled to B1; with B1, "catch up from the start" is true for every start. | Run 2, 69f53a5 |
| B3 | Fix the debug-only launch wait (`AppCore+Live.swift`): check `isPreparingModels` after every sleep, end only after 3 s in which every check found no preparation, log one line when it ends. Correct the docs that claim the wait always outlasts a compile. | Pre-flight found the cause in this project's wait loop, not in `TranscriptionService`: a process stall of more than 3 s ended the wait without a new check. Only DEBUG builds with `-chatLoadTest` are affected, but the measurement tool must not record beside a compile. | Run 3, steps 1 and 2 |
| B4 | 8 GB Macs answer during recordings: `waitForStopMaximumMemory` stays 0, as the decision rule says. The wait-for-Stop mode is kept. | The measured peak, 2.96 GB, is under an 8 GB Mac's 3 GB budget; the user chose the rule over phase 6's proposal. | Run 1, f514822 |
| B5 | No remedy for the live-transcript contention in Low Power Mode; the unused live hold is removed. | One decode 0.16 s over a limit that is half the watchdog's, no reset in any run, a catch-up of 0 s after every answer. | Run 1, f514822 |
| B6a | On Stop, close the chat card unless an answer is being written or waits for Stop. The band then reads "Continue chat" and one click reopens the thread. | After Stop & Save the card covered the new meeting page. A running answer stays in view. | Run 3, step 3 |
| B6b | Keep the character count under the text, at the field's right; reword `ui_design.md`. | Phase 10 moved it there (A14) so the text keeps its width. | Run 3, step 6 |
| B6c | Keep History's last-activity order: most recently used first, with the time of the last question or answer; reword `ui_design.md` and `functional_spec.md`. | The built order is the more useful one; the specs said "newest first". | Run 3, step 6 |
| B6d | Don't fix: "Continue chat" during the final pass is per spec (`ui_design.md`, the functional spec's availability table). | With a live draft, chat answers from the draft; the waiting text is for meetings recorded with the live transcript off. | Dismissed |
| B6e-1 | Give the message list's `LazyVStack` the open thread's ID as its identity, so each thread builds new rows. | A question bubble was missing once after a thread was picked from History. Never reproduced: this is an unproven remedy for a likely cause, not a confirmed fix. | Run 3, step 5 |
| B6e-2 | Don't fix now: about 0.2 s per typed letter near 1,900 characters. | Only very long typed questions; phase 10 recorded how to measure it. | Dismissed |
| B6e-3 | Move to the recording area's tracker: the "System audio may be denied" banner is a false alarm when meeting audio starts more than 2 s after Record, and is never cleared (the system track measured fine). | Not this project's code. The user files it; the manager drafts the text. | Dismissed, to the recording area's tracker |
| B6e-4 | In availability, count a live draft only when it has text (`ChatEvidence.hasText`); when a save has recorded "no text", it wins over a held draft. | A silent recording with the live transcript on offered chat, and the question then failed. | Run 3, step 4 |
| B6e-5 | Update `ui_design.md` to five built details: card border 0.5 pt; History time as a gray line under the name; typing dots on their own line under the text; Stop's square `cardFill`; reason and status text `inkSecondaryLegible`. | The design predates phase 8's built values, which passed phase 10's visual review. | Run 3, step 6 |
| B6e-6 | Don't build a development-only dark-mode launch argument. | Not needed. | Dismissed |
| B6e-7 | Leave the development store's Political Reform summary flagged as user-edited. | Development data only. | Dismissed |
| B7 | Move to the live transcript's tracker: small wheel scrolls in the live drawer are pulled back while text streams (its 24 pt rule), with a one-minute check with a real mouse and a trackpad. | `live_transcript`'s `FollowController`, not this project's code; a real mouse notch was never measured. The user files it; the manager drafts the text. | Dismissed, to the live transcript's tracker |
| B8 | Move: fix the flaky `EngineHostTests` cancel test where it was written, on the live-transcript branch. | A race in the test, which is the same on that branch and on `prod`; this project's package code does not own it. The user routes it; the manager drafts the fix note. | Dismissed, to the live-transcript branch |

## Steps

1. **B3: the launch wait** (`AppCore/AppCore+Live.swift`, inside `#if DEBUG`). `waitUntilModelsPrepared` gains a clock and returns how long it waited:

   ```swift
   @discardableResult
   func waitUntilModelsPrepared(
       settle: Duration = .seconds(3),
       poll: Duration = .milliseconds(500),
       clock: any Clock<Duration> = ContinuousClock()
   ) async -> Duration
   ```

   A generic helper on the opened clock runs the loop. Each pass checks `transcription.isPreparingModels` first: a check that finds preparation clears the idle start; a check that finds none sets it if unset, and ends the wait once `settle` has passed since it. Then it sleeps for `poll`. So the wait ends only right after a check that found no preparation, and only when every check of the last `settle` found none; a sleep that overruns (a process stall) is always followed by a check. When the wait ends (not cancelled), it writes one `chat-load` line: `launch-wait-done seconds=<s>`, which `analyze.py` ignores. The doc comment says the wait checks after every sleep and ends after `settle` of checks that found no preparation.
2. **B3: the docs.** Correct the claim that the launch always waits out a compile:
   - `research/chat_measurement/README.md`, "Launch wait" note: the driver checks after every sleep since this fix; before it, a stall of more than 3 s during a compile could end the wait early, which is what happened in `lowpower-e2b-aborted-1` (the final pass's model compiled again at the next launch). The analyzed runs are not affected.
   - `Tools/chat_bench/README.md` (the launch bullet): the launch counts as done once every check over 3 s found no model being prepared; the app writes `launch-wait-done`.
   - `Tools/chat_bench/run.sh` comment before the plan-line wait: the same rule.
3. **B6a: the card on Stop** (`AppCore/AppCore.swift`, `stopRecording()`). After `select(meetingID)`, close the meeting's chat card unless an answer is being written or waits for Stop in it (`MeetingChatState.isAnswering`). `stopRecording()` is the one path for the window's Stop, the menu bar, the shortcut and auto-stop. The open thread stays, so the band reads "Continue chat". `ui_design.md`, "Saved meeting page": one line saying so.
4. **B6e-4: a draft without text** (`MeetingChat/MeetingChatService.swift`, `availability(for:)`). A saved transcript with text makes chat available, as now. A held draft counts only when one of its rows has text by the evidence's rule (`ChatEvidence.hasText(row.settledText + row.tailText)`, a new `ChatEvidence.hasText(_ draft: LiveTranscriptSnapshot)`), and not when a save has recorded "no text" for the meeting (`flagsSetBySave` with a false flag). Otherwise the fallthrough is unchanged: transcribing or pending final pass → `.transcribing`, else `.noTranscript`. `components/meeting_chat_service.md`'s availability rules say the same.
5. **B6e-1: rows per thread** (`MeetingChatUI/ChatMessageList.swift`). `.id(state.openThreadID)` on the `LazyVStack`, so picking another thread builds its rows afresh instead of reusing the last thread's. A comment says why. The defect was never reproduced, so this is an unproven remedy; there is no view test for it.
6. **B6b, B6c and B6e-5: the specs, in one edit.**
   - `ui_design.md`: the count "under the text, at the field's right" (B6b); the History menu lists threads "most recently used first, with the time of its last question or answer" as a gray line under the name, since SwiftUI menus cannot right-align (B6c, B6e-5); the card's border 0.5 pt; the typing dots on their own line under the text; Stop's 9 pt square `cardFill`; the unavailable reason and the status line `inkSecondaryLegible` (B6e-5).
   - `functional_spec.md`: the History menu lists threads "most recently used first, with the time of its last question or answer" (B6c).
   - `ChatButtons.swift`: the Stop square's comment no longer calls `cardFill` a deviation from a white square.
   - Each changed spec artifact keeps `status: complete`.
7. **Close-out.** `backlog.md`: tick B3 and add its `**Status:** closed` line with this run's commit subject. Check that B1 to B3 are all closed. At the commit invocation, after review: tick Phase 11 in `implementation_plan.md` and set this plan to `status: complete`.

## Pending hardware checks

These are checked on hardware by the manager with the user after this run. They are not passed yet:

- **Run 2's catch-up:** turning the live transcript on mid-recording (from chat's Turn On and from Settings) fills the drawer from 0:00 with "Catching up…", then continues live; chat answers from what is transcribed so far.
- **B6a:** Stop & Save with the chat card open and no answer running opens the meeting page with the card closed and the band reading "Continue chat"; one click reopens the thread. With an answer running, the card stays open.

## Tests

- `AppCoreChatLoadTests.launchWaitChecksAfterStalledSleep`: with a `TestClock`, a compile in progress, and a 0.5 s sleep that lasts 4 s, the wait does not end (the old loop ended here); after the compile ends it ends 3 s after the first check that found none, and returns that time.
- `AppCoreChatLoadTests.launchWaitSeesCompileStartedDuringStall`: idle at the start, then a compile starts during a stalled sleep; the check after the stall finds it and the wait goes on, ending 3 s after the compile ends.
- `AppCoreChatTests.stopClosesCardUnlessAnswering` (arguments: answering or not): during a recording with an open chat card, Stop closes the card and keeps the thread when the answer has ended, and keeps the card open while an answer is being written.
- `MeetingChatAvailabilityTests.draftWithoutTextIsNotEnough`: a stopped recording whose draft rows hold only whitespace reads as transcribing until the pass ends, then as no transcript.
- `MeetingChatAvailabilityTests.savedNoTextWinsOverDraft`: a stopped recording with a draft that has text; a save that records no text makes the meeting read as no transcript while the draft is still held.
- `ChatEvidence` unit check in the same suite: a draft with whitespace-only rows has no text, one with a tail-only row has text.
