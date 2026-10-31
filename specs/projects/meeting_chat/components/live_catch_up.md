---
status: complete
---

# Component: Live catch-up from the recording files

Backlog decisions B1 and B2 (29 October 2026). The user: "if you turn on chat, you want the whole transcript … I think catch up should work."

## Purpose and Scope

When the live transcript starts in the middle of a recording with no live text before that moment, it catches up from 0:00, the same as a transcript that was on all along. It reads the recording's track files from the start up to where its live audio begins, hands that audio to the live engine through the catch-up path that already exists, and then continues live. There is no button.

These starts catch up from 0:00:

- the Settings toggle turned on during a recording;
- chat's "Turn On", which turns the same setting on;
- the live model finishing its download during a recording;
- switching back from a language the engine cannot transcribe. Switching to that language cleared the live text, so nothing before the restart has text either.

A language change between two languages the engine supports does not start a session: the running session finishes its words and goes on with the new language, keeping its text. A start with the recording is unchanged: the tap's queues hold the first seconds, and the pump holds up to 15 minutes while the engine starts. Without the recording's files (tests and previews), a start mid-recording starts from that moment, with a "Live transcript started at m:ss" line, as before.

This is the live transcript's own start behaviour. Chat's "Turn On" only turns the setting on, and chat still reads live text through `snapshot(includeTail:)` without changing how it is made.

Not its job: transcribing the files for the saved transcript (the final pass does that after Stop), or changing `AudioCapture` or `Transcription`.

Lives in `LiveTranscriptionService`: `RecordedTrackFile.swift` (the file read), `LiveFileCatchUp.swift` (the handoff, the chunker and the read), with changes in `LivePumpCore`, `LiveAudioPump` (`LiveChunkPipe.send`), `LiveRecordingSession` and `LiveTranscriptionService`. `RecordingController.capturePaths` and `AppCore` supply the file paths.

## Public Interface

```swift
/// The recording's track files.
public struct LiveRecordingFiles: Sendable {
    public init(mic: URL, system: URL)
}

extension LiveTranscriptionService {
    /// `files`: without them, a start mid-recording starts from that moment, with a start marker.
    public func start(meetingID: UUID, tap: any LiveAudioSource, files: LiveRecordingFiles? = nil,
                      timelineOffset: TimeInterval, recordingStartedAt: Date = Date()) async
}

extension RecordingController {
    /// The track files of the recording in progress; nil when none is.
    public private(set) var capturePaths: CapturePaths?
}
```

`startMarker` is nil for a start that catches up from 0:00.

## Internal Design

### Reading a file that is still being written

The track files are ADTS AAC, 24 kHz mono. Their timeline is the recording's: the writers fill capture gaps and device switches with silence, and the system track starts with the silence that aligns it with the mic. So frame `n` of a file is `n / 24000` seconds on the recording timeline, and the read needs no offset from `timelineOffset` (that offset only places notes, which count from capture start). There is no recording pause.

Three facts were measured on this Mac and are covered by `RecordedTrackFileTests`:

- **Encoder delay.** Apple's AAC-LC encoder starts every stream with 2,112 frames of delay. ADTS has no field for it, so `AVAudioFile` decodes every frame 2,112 frames late. `AACTrackFile` adds 2,112 to every read position.
- **A growing file.** An open `AVAudioFile` keeps the length it found when it opened. A read that needs audio past that length opens the file again (about 0.2 ms; seeking and reading 2 s at the end of a 20-minute file took 2 ms). The encoder keeps the file about 0.1 s behind the tap. A failure to open the file again, or to decode its last two packets, reads as no audio yet.
- **Seeking after a reopen is sample-exact.** In a 2-minute file at the recorder's settings (24 kHz, 64 kbps), reads from files opened afresh while the file grows decode exactly the samples one sequential read does, and tone bursts late in the file land on their frames.

`TrackFileChunker` turns a file into 250 ms chunks of 16 kHz audio from 0:00 with the same `TrackResampler` the pump uses. Its last chunk ends exactly where the pump's audio begins, and the next one continues from there, so the engine receives one continuous run.

### The handoff

`FileCatchUpHandoff` gives each track a route: `.file`, `.live`, `.liveAfterGap` or `.dropped`. The pump's queue and the file read share it, behind a mutex.

1. The session starts the pump with `discardBefore` at the moment of the start, as before, and one file read per track, off the main actor.
2. While a track reads its file, the pump offers none of its chunks to the pipe; they wait in the pump. Its first chunk tells the handoff where the held audio begins. The tap's overflow before that first chunk is not a gap, because the file covers it.
3. The read queues the file's chunks in the session's pipe (`LiveChunkPipe.send` waits for a free slot). The forwarder hands them to the engine as backfill, no further than `engineLead` past what it has transcribed, so the engine catches up in its 30 s windows. Engine restarts and language changes replay the unsettled audio as before.
4. When the read reaches the held audio, the track goes live and the pump hands its held chunks on, in order, with no discontinuity.
5. When the pump must drop held audio of a track still reading its file, it removes the chunks and moves the handoff in one step under the handoff's lock, so the read can never reach the old held audio in between.
6. If the read gives up after it sent file audio, the track goes `.liveAfterGap`: the first chunk the pump hands on is marked discontinuous, so the engine starts a new run there instead of joining it to the file's last audio, which would shift every later time on that track.

The store's transcript starts at 0:00 for these sessions. The status is Starting until the first update, then Catching up while the text is more than 10 s behind the audio, then Live.

### Limits

| Limit | Value | Why |
|---|---|---|
| Live audio held per track during the read | 15 minutes (`LiveTiming.pumpBacklog`, default `LiveAudioLimits.pumpBacklog`, unchanged) | The pump's existing memory bound, about 29 MB per track as 16-bit samples. |
| Audio the read can cover | The whole recording | When the held audio passes 15 minutes, the pump drops its oldest chunks as before, but while the track reads its file the handoff moves to the oldest chunk still held and the read goes on to it. No gap, and no more memory. On this Mac the engine caught up at about 10× real time, so a 2.5-hour recording's file part takes about 15 minutes. |
| Audio decoded ahead of the engine | The pipe's 8 chunks (2 s) plus at most 1 s being resampled | The read waits for the pipe, so it never decodes faster than the engine takes audio. |
| File stall | 5 s (`LiveTiming.fileStallLimit`) | The file trails the tap by about 0.1 s, and a device switch pauses both. A file that does not reach the needed time for 5 s has lost its writer. The read gives up, records the rest up to the held audio as a gap ("Not transcribed live"), and the track goes live after that gap. |

A file that does not open is a gap from 0:00 to the held audio. A file that cannot be decoded before its last two packets ends the read the same way, from where it stopped.

### Thermal pause

The existing pause rule applies to a catch-up too. While the Mac is paused for heat, the session hands every chunk over at once and the engine drops it as one paused gap. A catch-up that starts during a pause, or runs into one, reads the rest of the file quickly, without transcribing it: that part of the recording gets a "paused" gap and is never caught up. After the resume, the live transcript goes on from the live audio.

### Stop during a catch-up

What Stop does, exactly:

- The file reads stop at once. For each track still reading its file, the pump drops the live audio it holds and the forwarders drop the file chunks still in the pipe. The draft records one gap per such track, "Not transcribed live", from the end of what the engine took to the end of the track's audio. Its sound is not known, so it is not silent.
- Audio already handed to the engine, and the audio the pump holds for a track that already reached its live audio, finish under the existing stop deadline (10 s), as after any Stop with a backlog. The engine may hold up to `engineLead` (36 s) per track, about 7 s of decoding for both tracks at the measured 10×, so a Stop late in a catch-up can use most of the deadline, and on a slower Mac or beside a chat answer it can run out (`.timedOut`, then a worker reset before the final pass).
- `Live finish after Stop: <result> in <seconds> s` records how long the finish took.

The final transcript, made from the files after Stop, covers the whole recording.

### Drawer (B2)

- **Start marker:** none for a catch-up from 0:00. "Live transcript started at m:ss" no longer describes such a transcript. The line stays only for a start without the recording's files.
- **Slow-start text:** unchanged. "The transcript will catch up from the start." is now true for every start. With no start marker, the drawer's placeholder can show it for a start mid-recording too.
- **While it catches up:** rows fill in from 0:00, and the header shows "Catching up…" until the text reaches the live audio.

### Chat

While the catch-up runs, chat answers from the snapshot, which is contiguous from 0:00. The footer "Based on the transcript through m:ss" and the prompt's "The live transcript above runs through m:ss" both use the snapshot's `transcribedThrough`. With the transcript starting at 0:00, that is how far the text reaches, so neither changed. Before the first update it is 0:00, and a snapshot with no lines fails as "no transcript yet", as before.

### Logging (category `live`)

- `Live transcription starting mid-recording, catching up from 0:00`
- `The live catch-up reads the mic file from 0:00; the live audio begins at 312.48 s` (one per track: the file opened)
- `The live catch-up read the mic file from 0:00 through 312.53 s in 31.2 s; the live audio follows` (one per track: the handoff)
- `The live mic audio waiting for the catch-up passed the pump's 900 s; the file read covers what is dropped` (once per track, only for long catch-ups)
- `The live catch-up stopped reading the system file after 4.1 s: …` (error: the read gave up)
- `Stop during the live catch-up: mic, system stop reading the recording files; the rest is not transcribed live`
- `Live finish after Stop: finished in 2.31 s` (how long Stop's finish took)
- The existing `Live status: catchingUp` and `Live status: live` lines show the drawer's state.

## Dependencies

`AVFoundation` (`AVAudioFile`) for the read. `AudioCapture` for the tap types, as before. Nothing in `Packages/AudioCapture`, `Packages/Transcription`, `Packages/LocalLLM` or `MCPServer` changed.

## Test Plan

`LiveTranscriptionServiceTests/LiveFileCatchUpTests.swift`:

- `RecordedTrackFileTests`: a real ADTS file written as the recorder writes it (24 kHz, 64 kbps) reads on the recording timeline without the encoder delay; a file still being written is read as it grows; reads that reopen and seek a growing 2-minute file match one sequential read sample for sample; a missing file does not open.
- `TrackFileChunkerTests`: chunks from 0:00 end exactly at the handoff and continue there; 24 kHz becomes 16 kHz at exact times; a short file gives no chunk until it grows.
- `FileCatchUpHandoffTests`: routes, the read target following the pump's drops, giving up and abandoning.
- `LivePumpCoreCatchUpTests`: held chunks and no overflow gap while reading; a catch-up past the 15-minute retention drops into the file with no gap; after a give-up the first chunk handed on is discontinuous; an abandoned track drops its audio and the pump ends.
- `LiveFileCatchUpTests`: the read reaches the pump's audio and goes live; it reads on through audio the pump dropped meanwhile; a stalled file or one that does not open gives up with a gap; an abandoned read ends.
- `LiveChunkPipeSendTests`: `send` waits for a slot of its own track and stops when the pipe finishes or the task is cancelled.

`LiveTranscriptionServiceTests.swift`, suite "catch-up from the recording files": file audio before live audio, contiguous from 0:00, with no gap or marker; the drawer and chat state while catching up, and Catching up turning Live after the join; the model download and the restart after an unsupported language catching up; a supported language change and an engine restart during a catch-up; the pump dropping into the file with a short backlog; a give-up starting a new run in the engine; Stop during a catch-up finishing in time with the rest as a gap.

Also `AppCoreLiveTests` (the Settings toggle catches up), `RecordingViewModelLiveCatchUpTests` in `RecordingViewModelLiveTests.swift` (no start marker line in the drawer) and `RecordingControllerTests` (`capturePaths`).
