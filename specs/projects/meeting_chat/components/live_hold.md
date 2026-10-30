---
status: complete
---

# Component: Live hold

> **Not built: removed by Backlog decision B5 (29 October 2026).** Phase 7 built this design, switched off on every Mac, as one of the remedies for the chat measurement's contention result. The user chose no remedy: answers run beside the live transcript on every Mac. The hold, the `.holdLiveTranscript` mode, the `concurrent-e2b-hold` plan, the held-run analysis and their tests were removed. This doc is kept as a record of the design; see [research/chat_measurement](../research/chat_measurement/README.md#phase-7-remedies).

> **Contingency, not built by default.** Chat runs beside the live transcript, which falls behind and catches up on its own (decided 27 October 2026). This design is built only if the [chat measurement](chat_measurement.md#decision-rule) shows answers trip the live transcript's stuck-decode watchdog, stall a single decode for 5 s or more, or leave the live text more than 30 s behind. It saves no memory: the live speech model stays loaded while held.

## Purpose and Scope

A way for another feature to stop live transcription's decoding for a short time and have it catch up afterwards, with no audio lost and no gap marker. Chat takes a hold while it writes an answer on Macs where the [resource policy](meeting_chat_service.md#resource-policy) says the two should not run together.

Not its job: the thermal pause (which stays as it is and still drops audio), deciding when to hold (the chat service decides), or anything about the recording itself, which never stops.

Lives in `LiveTranscriptionService` (`LiveTranscriptionService.swift` and `LiveRecordingSession.swift`).

## Public Interface

```swift
/// Held decoding. Release it once; releasing twice does nothing. A hold that is never
/// released is released by its `maximum` timeout (a main-actor class cannot release
/// from `deinit`).
@MainActor
public final class LiveDecodingHold {
    public let reason: String
    public func release()
}

extension LiveTranscriptionService {
    /// Stops handing audio to the live engine and pauses its decoding until every hold is
    /// released. Audio keeps arriving and waits in the session's pipe (up to
    /// `LiveAudioLimits.pumpBacklog`, 15 minutes per track), then is handed over as
    /// backfill, so the transcript catches up with no gap.
    /// Holds also apply to a session that starts while they are held.
    public func holdDecoding(reason: String, maximum: Duration = .seconds(120)) -> LiveDecodingHold

    /// True while at least one hold is held. For tests and logging.
    public var isDecodingHeld: Bool { get }
}
```

`maximum` is a safety limit: a hold still held after it is released automatically, with a log warning. Chat answers end well before 120 s; the limit protects the transcript if a caller forgets.

## Internal Design

**Service level** (`LiveTranscriptionService`, main actor):
- `holds: [ObjectIdentifier: LiveDecodingHold]`. `holdDecoding` adds one, schedules its `maximum` timeout, and calls `current?.setHeld(true)` when the set goes from empty to non-empty. `release()` removes it and calls `setHeld(false)` when the set becomes empty.
- `startSession(...)` passes `isHeld: !holds.isEmpty` into the new `LiveRecordingSession`.
- When a recording stops, holds are released (the session ends anyway).

**Session level** (`LiveRecordingSession`):
- New state `isHeld: Bool`.
- `setHeld(_ held:)` sets it, calls `resumeProgressWaiters()` (so forwarders re-check), `publishSoon()`, and `syncEnginePower()`.
- In `deliver(_:isReplay:)`, before the pause check: `guard !isHeld else { await waitForRelease(); continue }`. A held chunk is neither offered nor dropped; it stays in hand while newer audio waits in the pipe, exactly as when the engine is behind. `waitForRelease()` suspends on a continuation list resumed by `setHeld(false)` and by `finish`.
- `syncEnginePower()` compares the engine's paused state with `setup.power.isPaused || isHeld` instead of `setup.power.isPaused`, so the engine stops its decode loop while held and resumes on release. `enginePower` gains an `isHeld` component so a change in either triggers the sync.
- `isPaused` (the thermal pause that drops audio) is untouched. If both apply, the thermal pause wins: chunks are dropped as a gap, as today.
- After release, the waiting chunks are handed over. Those more than `backfillLag` behind are marked backfill and decoded at catch-up speed. The store reports `.catchingUp` on its own while a track is more than 10 s behind, so the drawer shows "Catching up…" without new code.
- The latency signpost ignores backfill chunks already, so held audio does not distort latency figures.

**Finish while held:** `finish` releases the hold first, so the final flush decodes the held audio within the finish timeout, as for any backlog.

## Dependencies

- Uses the session's existing pipe, `deliver`, `waitForProgress`, `syncEnginePower` and `LiveAudioLimits`.
- Used by `MeetingChatService`.

## Test Plan (`LiveTranscriptionServiceTests/LiveDecodingHoldTests.swift`)

Uses the existing fake live engine and clock.

- `holdStopsOffers`: while held, the fake engine is offered no chunks and is set paused; chunks keep arriving at the pipe.
- `releaseCatchesUpWithoutGap`: after a 20 s hold and release, every chunk from the hold is offered in order, the later ones marked backfill, and no `LiveGap` is recorded.
- `statusCatchesUpAfterLongHold`: after a hold longer than 10 s, status becomes `.catchingUp`, then `.live` once the fake engine reports progress.
- `twoHoldsNeedTwoReleases`: decoding resumes only when the second of two holds is released.
- `doubleReleaseIsHarmless`: releasing a hold twice does not release another holder's hold.
- `maximumReleasesAndLogs`: a hold kept past `maximum` is released by the timeout.
- `thermalPauseStillDropsAudio`: with a thermal pause and a hold both active, audio is dropped as a gap, as before.
- `holdCarriesIntoNewSession`: a hold taken before a recording starts applies to its session from the first chunk.
- `finishFlushesHeldAudio`: stopping a recording while held decodes the held audio in the finish.
