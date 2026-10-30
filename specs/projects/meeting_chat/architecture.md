---
status: complete
---

# Architecture: Meeting chat

This is the technical design for the [functional spec](functional_spec.md) and the [UI design](ui_design.md). It builds on the `live_transcript` project, whose snapshot API, drawer and worker this project reads and, in one place, extends. Each component below has its own design doc under [components/](components/); this file holds the shape, the decisions that cross components, and the order in which things depend on each other.

## What already exists, and what it means for chat

| Fact (from the code) | Consequence |
|---|---|
| Each `LLMService.withConnection` opens its own XPC connection, and each connection loads its own copy of the model in the `BiscottiLLM` process. Two open connections mean two model loads. The service process exits when its last connection closes. | Chat must never open a second connection beside the summary's. One owner of the connection, the **LLM broker**, serves both. |
| `LLMConnection` reuses the KV cache for the shared prefix of consecutive calls on one connection. Nothing is reused across connections. | Keeping one connection open across a thread's questions makes follow-up answers fast, as long as the prompt's stable parts come first. |
| `Intelligence` runs one analysis at a time through `inFlightMeetingID`, and **drops** a second request rather than queuing it. It has no cancel API. | `Intelligence` keeps that guard for its own requests. Its model access moves onto the broker, which then orders analysis and chat on one connection. |
| A cancelled `generateStreaming` stream can end with neither `.done` nor an error. | The chat treats "ended without `.done`" as stopped or failed, never as a finished answer. |
| `TranscriptFormatter.plain` writes `Speaker: text` lines with no times. | Chat needs its own formatter with a time on every line, so answers can cite moments. |
| `LiveTranscriptionService.snapshot(includeTail:)` returns a frozen `LiveTranscriptSnapshot`, and `draft(for:)` returns a stopped recording's draft. | Chat reads the live text through these and changes nothing in how it is made. That still holds with the catch-up from the recording's files (Backlog decision B1): catching up from 0:00 is the live transcript's own behaviour for every start mid-recording with no live text before it (Settings, chat's Turn On, the model download, switching back from an unsupported language). Chat's Turn On only turns the setting on. |
| The live transcript already falls behind and catches up from its backlog when its engine is slow, with no audio lost. Its only explicit pause, the thermal one, drops the paused audio as a gap. Its watchdog resets the speech worker only for a decode that is still running 10 s after a live session ends, for example at Stop or at a language change. | Chat runs beside the live transcript and lets it fall behind and catch up. A **hold** that pauses decoding without dropping audio was designed as a contingency and is not built (Backlog decision B5). |
| `DataStore` is an actor with one SwiftData V1 schema. New models and new properties with defaults need no migration stage. The UI learns of changes through `@Observable` services and reloads, not through store notifications. | Chat threads are two new V1 models. The chat service is `@Observable` and is the UI's source of truth while a thread is open. |
| ⌘J and ⌘N are not bound anywhere in the app. | "Ask About This Meeting" takes ⌘J, and "New Chat" takes ⌘N while the chat card has focus. |

## Components

```
              MeetingChatUI  (field, card, history menu, answer renderer)
                   │                         ▲
      RecordingUI ─┤                         │ observes
  MeetingDetailUI ─┘                         │
                                     MeetingChatService ──── DataStore (ChatThread, ChatMessage)
                                     │      │       │
                     ChatContextBuilder     │       └──── LiveTranscriptionService (snapshot, draft)
                     (evidence, selection,  │
                      prompts, citations)   │
                                            ▼
                                       LLMBroker ◄──── Intelligence (summary, title, speakers)
                                            │
                                       LocalLLM → BiscottiLLM.xpc
```

| Component | Module | Responsibility | Design doc |
|---|---|---|---|
| `LLMBroker` | `Intelligence` | Owns the one connection to the local model. Leases it to one job at a time in priority order, keeps it open briefly between jobs, and closes it on idle, model change or memory policy. | [llm_broker](components/llm_broker.md) |
| Chat storage | `DataStore` | `ChatThread` and `ChatMessage` models, a `Meeting.chatThreads` cascade relationship, Sendable read models and write methods. | [chat_store](components/chat_store.md) |
| `ChatContextBuilder` | `MeetingChat` (new) | Turns a meeting's transcript, notes and details, plus the thread so far, into the model's messages. Formats timestamped evidence, selects passages for meetings that do not fit, and parses and checks the times an answer cites. Pure functions, no I/O. | [chat_context](components/chat_context.md) |
| `MeetingChatService` | `MeetingChat` (new) | The `@MainActor @Observable` source of truth for chat: availability per meeting, open threads, the answer being written, asking, stopping, retrying, history and deletion. Persists through `DataStore` and answers through `LLMBroker`. | [meeting_chat_service](components/meeting_chat_service.md) |
| Live hold (not built) | `LiveTranscriptionService` | Not built. Phase 7 built it, switched off on every Mac, as a remedy for the measurement's contention result; Backlog decision B5 (29 October 2026) chose no remedy and removed it. It was a lease that stopped feeding audio to the live engine while held and let it catch up afterwards, with no gap. | [live_hold](components/live_hold.md) |
| Live catch-up | `LiveTranscriptionService`, with `RecordingController.capturePaths` and `AppCore` supplying the files | A start mid-recording reads the recording's track files from 0:00 up to where its live audio begins, queues that audio ahead of the live audio through the existing catch-up path, then continues live. Backlog decisions B1 and B2. | [live_catch_up](components/live_catch_up.md) |
| Chat UI | `MeetingChatUI` (new), plus small changes in `RecordingUI`, `MeetingDetailUI`, `DesignSystem`, `TranscriptUI`, `AppShellUI` and `App` | The field, card, history menu and answer rendering from the UI design, and their placement on both screens. | [chat_ui](components/chat_ui.md) |
| Measurement | A DEBUG load driver in `MeetingChat`, and `Tools/chat_bench` | Asks fixed questions in Biscotti Dev while a recorded meeting plays, and records memory, live delay, answer speed and citation validity. Its results set the resource policy. The driver stays on the development branch. | [chat_measurement](components/chat_measurement.md) |

### New modules and dependencies

Two new targets in `Packages/BiscottiKit/Package.swift`, each with a `.library` product, `warningsAsErrors`, and a test target:

- `MeetingChat` depends on `DataStore`, `Intelligence` (for `LLMBroker`, `ModelManager` and `LLMRunning`), `LiveTranscriptionService`, `LiveTranscriptModel` and `Formatting`. Its tests are `MeetingChatTests`, which also use `BiscottiTestSupport`.
- `MeetingChatUI` depends on `MeetingChat`, `DesignSystem` and `TranscriptUI`. Its tests are `MeetingChatUITests`.
- `AppCore` gains `MeetingChat`. `RecordingUI` and `MeetingDetailUI` gain `MeetingChatUI`. `BiscottiTestSupport` gains `MeetingChat`, so `CoreFixture` can expose the chat service with a fake model.

`MeetingChat` never imports a UI module, and `LiveTranscriptionService` never imports `MeetingChat`.

## The flow of one answer

1. The user sends a question. `MeetingChatService.ask(_:meetingID:)` checks availability, creates the thread if needed, and saves the question as a `ChatMessage` at once.
2. It gathers the evidence on the main actor:
   - **During a recording:** `liveTranscription.snapshot(includeTail: true)`.
   - **On a saved meeting:** `store.meetingDetail(id:)`, using `preferredTranscript`, or `liveTranscription.draft(for:)` if there is no saved transcript yet.

   It also takes the notes, title, date and invitees, and the thread's earlier turns.
3. `ChatContextBuilder.messages(for:)` returns the messages, the context size to use, and the evidence index used later to check cited times. This is pure and fast.
4. During a recording, the resource policy decides whether the answer runs now, beside the live text, or waits for Stop. No Mac waits for Stop by default (Backlog decision B4); the wait-for-Stop mode remains, reachable only from tests and the chat load driver.
5. It requests a lease from `LLMBroker` at `.interactive` priority. While waiting, the status line says why ("Loading the AI model…", "Waiting for the summary to finish…").
6. In the lease, it calls `reconfigure(contextSize:)` only if the size changed, then `generateStreaming`. Tokens are appended to the in-memory answer; the UI observes it and redraws at most every 50 ms.
7. The stream ends:
   - `.done`: the answer is saved as complete, with the transcript cutoff and kind.
   - The user pressed Stop: the answer is saved as stopped.
   - An error, or an end without `.done`: the answer is saved as failed, with a short message.
8. The lease is returned. The broker keeps the connection open for its idle period, or closes it at once if the policy says so.

## Cross-cutting decisions

**One model connection.** `LLMBroker` is created by `AppCore` and given to both `Intelligence` (through a broker-backed `LLMRunning`, so `Intelligence`'s own code barely changes) and `MeetingChatService`. Priorities, highest first: `interactive` (chat), then `background` (summary, title and speakers). A lease already running is never pre-empted: per the functional spec, a question waits for a running analysis to finish. A waiting chat question is served before waiting analysis.

**Prompt order for cache reuse.** Messages are built so the parts that change least come first: the rules, the meeting details, the transcript, the notes, then the conversation. A new question in the same thread then reuses the cached transcript. A transcript that has grown during a recording reuses everything up to its old end.

**Times.** Every evidence line starts with its time on the recording timeline, as `[m:ss]` or `[h:mm:ss]`. The model is told to cite moments in the same form. The renderer turns a cited time into a chip only if it falls within 15 seconds of a line given as evidence; any other time stays plain text. A chip's action carries the line's own start time.

**Persistence granularity.** A question is saved when it is sent. An answer is saved once, when it finishes, stops or fails. While it streams, it lives only in `MeetingChatService`. If the app quits or crashes mid-answer, the question remains, with an "Interrupted" answer and Retry.

**Recording priority.** The recording never waits for chat. Chat work runs off the main actor except for snapshotting and UI state. The live transcript is not paused for chat; when the AI keeps the GPU busy, the live text falls behind and catches up on its own.

**Resource policy during a recording.** One rule chooses `.concurrent` or `.waitForStop` from the Mac's memory. After the measurement the memory threshold stays 0 (Backlog decision B4), so every Mac runs `.concurrent`. The policy also tells the broker whether to keep the connection open after an answer during a recording: on Macs under 24 GB it closes at once, to free the AI model's memory for the rest of the meeting. There is no third mode: the measurement's contention result is accepted with no remedy (Backlog decision B5).

## Error handling

| Failure | Where it is handled | What the user sees |
|---|---|---|
| No AI model downloaded | `MeetingChatService` availability | The disabled field with "Open Settings" |
| Model fails to load, or the XPC service exits | `LLMBroker` drops the connection and fails the lease; the next lease reconnects | The answer fails with Retry |
| Stream ends without `.done` after Stop | `MeetingChatService` | The answer saved as stopped |
| Stream ends without `.done` or with an error, no Stop | `MeetingChatService` | The answer fails: "The AI stopped before finishing." |
| The prompt is too long even after selection | `ChatContextBuilder` lowers the evidence budget once more; if it still does not fit, it fails | The answer fails: "This meeting is too long to answer from." |
| A store write fails | `MeetingChatService` logs it and shows the answer in memory, marked as not saved | A small "Couldn't save this answer" line |

Logging uses `os.Logger` with subsystem `net.scosman.biscotti` and category `meeting-chat`, like the other services. The broker logs lease waits, model loads (with `GenerationResult.loadDuration`), reconfigures and idle closes. Question and answer text is never logged.

## Testing strategy

- **Unit tests (Swift Testing),** per component, in each component's doc:
  - `ChatContextBuilder` is pure and tested with fixed transcripts.
  - `LLMBroker` is tested with a fake `LLMRunning` and a test clock.
  - Storage is tested on an in-memory `DataStore`, plus one on-disk test that opens a store created without the chat models.
  - `MeetingChatService` is tested through `CoreFixture` with a scripted fake model that streams tokens, stalls, fails and ends without `.done`.
- **UI:** view-model tests for the field states, availability text and history menu content, plus SwiftUI previews of every state in the UI design.
- **AI test** (`make test-ai`, run by a human): the real model answers a fixed set of questions about a fixture transcript, and at least 90% of its cited times must be valid.
- **Measurement:** the chat measurement run on hardware decides the resource policy; its results are written to `research/`.
- **Manual tests:** this project does not touch `Packages/Transcription`, `AudioCapture`, `LocalLLM` or `MCPServer`, so no manual-test results are reset.
