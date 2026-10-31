---
status: complete
---

# Phase 7: The live hold, and the two remedies measured

## Overview

Phase 6's `lowpower-e2b` run failed the contention rule: one live decode inside question 4's answer took 5.16 s against the 5 s limit, with no watchdog reset and a catch-up of 0 s after every answer. This phase builds the contingency the component docs describe and measures both remedies, so the user can choose:

- the [live hold](../components/live_hold.md) in `LiveTranscriptionService`, and the chat service's `.holdLiveTranscript` mode, which takes a hold for the length of each answer during a recording;
- a measured run of the hold in the failing condition (`lowpower-e2b-hold`: the `concurrent-e2b` plan with the hold forced, Low Power Mode on);
- an estimate of the other remedy, a higher watchdog limit while an answer runs, from the five phase 6 runs.

**The policy's default does not change.** `ChatResourcePolicy.holdsLiveTranscript` is false on every Mac, so no tier holds the live transcript until the user chooses a remedy. Only a plan forces the mode, through the driver's existing override. `Packages/Transcription` does not change: the watchdog remedy changes it only if the user chooses it, after this phase.

## Steps

1. **`LiveDecodingHold`** (`LiveTranscriptionService.swift`, public, `@MainActor`): `reason`, `release()`. A second `release()` does nothing. It keeps the time it was taken and its timeout task, and an `invalidate()` the service uses when it drops the hold itself (at Stop, or at the timeout).

2. **Service level** (`LiveTranscriptionService`):
   - `@ObservationIgnored private var holds: [ObjectIdentifier: LiveDecodingHold]` and the time decoding was first held.
   - `public func holdDecoding(reason: String, maximum: Duration = .seconds(120)) -> LiveDecodingHold`: adds the hold and schedules its timeout (a hold still held at `maximum` is released, with an error line). On the first hold: logs `Live decoding held (<reason>)` and calls `current?.setHeld(true)`.
   - `public var isDecodingHeld: Bool`.
   - A release that empties the set logs `Live decoding resumes after a <s> s hold, <s> s behind` (the lag of the current session's live text, when one runs) and calls `current?.setHeld(false)`.
   - `startSession` passes `isHeld: isDecodingHeld` to the new session, so holds apply to a session started while they are held.
   - `stop(_:)` drops every hold (invalidated, logged), and the detached session's `finish()` releases its own held state first.

3. **Session level** (`LiveRecordingSession.swift`):
   - `private(set) var isHeld`, set from `init(setup:latency:isHeld:)`.
   - `setHeld(_:)`: sets it, resumes the progress and release waiters, `publishSoon()`, and syncs the engine's power in a task.
   - `enginePower` becomes `EnginePower { power: PowerPolicy.Decision; isHeld: Bool; isPaused: power.isPaused || isHeld }`. `syncEnginePower()` brings the engine to `EnginePower(power: setup.power, isHeld: isHeld)`: it pauses the engine while held and resumes it on release. Before a hold's pause it waits until no offer is in flight, so a chunk already on its way reaches the engine before the pause (the worker drops audio it receives while paused, as a gap). Each change resumes the release waiters.
   - `deliver(_:isReplay:)`: after the replay checks and before the lead check, `guard isPausedNow || !holdsDelivery else { await waitForRelease(); continue }`. `holdsDelivery` is `isHeld || enginePower?.isHeld == true`: a released hold keeps chunks back until the engine has resumed. The chunk stays in hand; newer audio waits in the pipe and the pump (`LiveAudioLimits.pumpBacklog`). The thermal pause wins: its audio is still handed over and dropped as one gap.
   - The release waiters are also resumed by `applyPower` (a thermal pause hands audio over) and `tearDown`.
   - `startEngine` sets the new engine's `enginePower` before it wakes the forwarders.
   - `finish()` calls `setHeld(false)` first, so the held audio is decoded within the stop deadline, as any backlog.

4. **Store** (`LiveTranscriptStore.swift`): `var lag: TimeInterval?`, how far the active track furthest behind is from the newest captured audio; `isCatchingUp` uses it (unchanged behavior). The service logs it at release.

5. **Chat** (`MeetingChat`):
   - `ChatResourcePolicy.Mode.holdLiveTranscript`; `public var holdsLiveTranscript: Bool` (default false, with a doc comment that no Mac holds until the user chooses a remedy). `mode()`: `.waitForStop` by memory as now, then `.holdLiveTranscript` when `holdsLiveTranscript`, else `.concurrent`.
   - `MeetingChatService.runAnswer`: during a recording in `.holdLiveTranscript` mode, `live.holdDecoding(reason: "chat")` before the evidence and the lease; released when the model's part ends, before the answer is saved. Logged as `Policy holdLiveTranscript: …`.
   - `ChatLoadPlan.Mode.holdLiveTranscript`; `override(mode:closesAfterAnswer:)` sets `holdsLiveTranscript` (true only for that mode) as well as the wait limit.

6. **Plan** `Tools/chat_bench/plans/concurrent-e2b-hold.json`: `concurrent-e2b` with `"name": "concurrent-e2b-hold"` and `"mode": "holdLiveTranscript"`.

7. **`analyze.py`**:
   - Reads `Live decoding held (…)`, `Live decoding resumes after a <s> s hold, <s> s behind`, `Live session ended with <n> rows and <n> gaps. <detail>`, `Live finish after Stop: <result>` and the store's `Live settled text changed instead of growing` fault.
   - Per answer: the hold's length and how far behind the live text was at its release (`heldSeconds`, `behindSeconds`).
   - `longestDecodeMs.afterAnswers`: decodes that start within 30 s of an answer's done (before the next window), where a hold moves the answer's decode load.
   - Loss: `liveGaps` (count, with sound, by reason, from the session-end lines), `rejectedLiveUpdates`, `liveFinish`.
   - **The rule for a held run** (plan mode `holdLiveTranscript`): no decode can start inside a held window, so the decode limit applies to the decodes inside the answer windows (a decode already running when the hold began) and those after the answers. A held run without decode lines in either is undetermined. Resets and the catch-up apply unchanged. Other runs keep the rule as it is.
   - Table rows: the hold per answer, the longest decode after answers, the live gaps, rejected updates and the finish after Stop.

8. **README** (`Tools/chat_bench/README.md`): the new plan and mode, how the rule applies to a held run, and the new rows.

9. **Measure**: build Biscotti Dev into `DerivedData/Development-meeting-chat` once, after the checks. A background chain creates `.specs_skill_state/phase7-waiting-for-low-power`, waits up to 3 hours for `pmset` `powermode 1`, deletes the marker, and runs `run.sh lowpower-e2b-hold concurrent-e2b-hold`. A run that starts no recording is moved aside and repeated after 2 minutes, at most twice.

10. **Write-up** (`research/chat_measurement/README.md`, new section "Phase 7: remedies"): the held run next to `lowpower-e2b` (lag during each answer, catch-up, loss, decodes, resets, answer speed); the watchdog remedy estimated from the five phase 6 runs (longest decode inside answers against a raised limit, resets), and its cost (`Packages/Transcription`, the `tx_*` manual tests reset, slower detection of a stuck decode during answers); the three options for the user (the hold on slower Macs, the raised watchdog limit while answering, no change), without choosing.

## Tests

`LiveTranscriptionServiceTests/LiveDecodingHoldTests.swift` (the fake live engine; `LiveFixture` becomes internal):
- `holdStopsOffers`: while held, the engine is offered no chunks and is set paused; the pump keeps taking the audio.
- `releaseCatchesUpWithoutGap`: after 20 s of audio held and a release, every held chunk is offered in order, those more than the backfill lag behind marked backfill and the newest not, no chunk reaches the engine while it is still paused, and no gap is recorded.
- `statusCatchesUpAfterLongHold`: a hold longer than 10 s turns the status to `.catchingUp`, then `.live` once the engine reports progress after the release.
- `twoHoldsNeedTwoReleases`: decoding resumes only when the second of two holds is released.
- `doubleReleaseIsHarmless`: releasing a hold twice does not release another holder's hold.
- `maximumReleasesTheHold`: a hold kept past `maximum` is released by its timeout; a later `release()` does nothing.
- `thermalPauseStillDropsAudio`: with a thermal pause and a hold, audio is handed to the paused engine as before; once the Mac cools and the hold remains, audio waits again.
- `holdCarriesIntoNewSession`: a hold taken before a recording starts applies to its session from the first chunk.
- `finishFlushesHeldAudio`: Stop while held drops the hold, hands the held audio to the engine before its finish, and leaves no gap.
- `releaseWaitsForTheEngineToResume`: with an engine slow to resume, no held chunk is offered before it has resumed (`FakeLiveEngine` gains `pauseDelay` and `offeredWhilePaused`).

`MeetingChatTests`:
- `MeetingChatPolicyTests.policyNeverHoldsByDefault`: 8, 16, 24 and 64 GB never give `.holdLiveTranscript` with the defaults; `holdsLiveTranscript` gives it, except where the Mac waits for Stop.
- `MeetingChatPolicyTests.holdModeHoldsLiveTranscriptWhileAnswering`: during a recording in hold mode, the live transcript is held while the answer streams (engine paused, no new audio offered) and released after it; outside a recording nothing is held.
- `ChatLoadDriverTests.planParses`: the fifth plan, with mode `holdLiveTranscript`.
- `ChatLoadDriverTests.overrideForcesMode`: the override forces `.holdLiveTranscript` and clears it for the other modes.

`Tools/chat_bench/test_analyze.py`:
- A held excerpt: hold and resume lines matched to answers; the lag and hold length per answer; decodes after answers; the rule applied to a held run (passes with a short in-flight decode, fails on a 5 s catch-up decode, undetermined without decodes in or after the answers).
- Gaps, rejected updates and the finish result from the session lines; the table's new rows.
