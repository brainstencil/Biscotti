---
status: complete
---

# Component: Meeting chat service

## Purpose and Scope

`MeetingChatService` is the chat's source of truth while the app runs. For each meeting it knows whether chat is available, which threads exist, which thread is open, whether the card is open, and the answer being written. It asks, stops, retries, opens, starts and deletes threads, persisting through `DataStore` and answering through `LLMBroker` with prompts from `ChatPromptBuilder`. During a recording it applies the resource policy.

Not its job: drawing (the UI observes it), prompt text and parsing ([chat_context](chat_context.md)), model access ([llm_broker](llm_broker.md)), or storage details ([chat_store](chat_store.md)).

Module `MeetingChat`, files `MeetingChatService.swift`, `MeetingChatState.swift`, `ChatResourcePolicy.swift` and `ChatErrorText.swift`.

## Public Interface

```swift
public enum ChatAvailability: Equatable, Sendable {
    case available
    case noModel                    // "Download the AI model to ask about meetings"
    case liveTranscriptOff          // "Turn on the live transcript to ask during the meeting"
    case noTranscript               // "This meeting has no transcript to ask about"
    case transcribing               // "Ask once the transcript is ready"
    case answeringElsewhere         // "Answering in another meeting…"
}

public enum ChatAnswerStatus: Equatable, Sendable {
    case loadingModel               // "Loading the AI model…"
    case waitingForSummary          // "Waiting for the summary to finish…"
    case waitingForRecordingToEnd   // "Answers when the recording stops"
    case thinking                   // "Thinking…"
    case streaming
}

public struct ChatMessageView: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case complete, stopped, interrupted, failed(String), streaming(ChatAnswerStatus)
    }
    public let id: UUID             // the stored message ID, or a temporary ID while streaming
    public let questionID: UUID     // for answers: the question they answer (Retry)
    public let role: ChatRole
    public let text: String
    public let blocks: [ChatBlock]  // answers only, from ChatAnswerParser
    public let state: State
    public let footer: String?      // "Based on the transcript through 0:46", "Based on the draft transcript"
    public let isUnsaved: Bool      // the store write failed
}

/// One meeting's chat, observed by its field and card.
@MainActor @Observable
public final class MeetingChatState {
    public let meetingID: UUID
    public internal(set) var availability: ChatAvailability
    public internal(set) var threads: [ChatThreadSummary]   // newest first
    public internal(set) var openThreadID: UUID?            // kept across launches
    public internal(set) var messages: [ChatMessageView]    // the open thread, oldest first
    public internal(set) var isAnswering: Bool
    public var isCardOpen: Bool
    public var draft: String                                // the field's text, kept per meeting and across launches
}

@MainActor @Observable
public final class MeetingChatService {
    public init(
        store: DataStore,
        broker: LLMBroker,
        modelURL: @escaping @MainActor () -> URL?,                     // ModelManager.activeModelURL
        live: LiveTranscriptionService,
        recordingMeetingID: @escaping @MainActor () -> UUID?,          // from AppCore's recording state
        isTranscribing: @escaping @MainActor (UUID) -> Bool,           // from TranscriptionService.jobs
        policy: ChatResourcePolicy = .forThisMac(),
        answerFlushInterval: Duration = .milliseconds(50),
        clock: any Clock<Duration> = ContinuousClock(),
        defaults: UserDefaults? = nil                                  // keeps open threads and drafts across launches
    )

    /// The state object for a meeting, created on first use and kept while the app runs.
    /// It starts on the open thread and the draft kept from the last launch.
    public func state(for meetingID: UUID) -> MeetingChatState
    /// Loads the meeting's threads and reopens its last open thread (after a relaunch, the
    /// kept one; a kept thread that is gone is forgotten). Call when the meeting's
    /// page or recording screen appears. `hasTranscript` is the caller's reading
    /// (`hasTranscriptToAsk(_:)`); nil reads the store.
    public func load(meetingID: UUID, hasTranscript: Bool? = nil) async
    /// The line a time chip goes to, for its preview: in the transcript a chip click shows
    /// (live while this meeting records, else the preferred transcript, else the draft),
    /// the line starting at `time`, else the last line starting before it.
    public func citedLine(at time: TimeInterval, meetingID: UUID) async -> ChatEvidenceLine?
    /// A pass saved the meeting's preferred transcript; `hasText` from `hasTranscriptText(_:)`.
    /// Availability itself is computed on each read from observable state
    /// (`MeetingChatState.availability`), so model, setting and recording changes need no call.
    public func transcriptWasSaved(meetingID: UUID, hasText: Bool)
    /// From Stop until the final pass ends, a meeting with no transcript and no draft reads as transcribing.
    public func finalPassWillStart(meetingID: UUID)
    public func finalPassDidEnd(meetingID: UUID)
    /// The one rule for "has text": a preferred transcript's, and the save hook's segment texts.
    public nonisolated static func hasTranscriptToAsk(_ transcript: TranscriptData?) -> Bool
    public nonisolated static func hasTranscriptText(_ segmentTexts: [String]) -> Bool

    public func ask(meetingID: UUID) async           // sends state.draft, then clears it
    public func stop()                                // stops the answer being written, anywhere
    public func retry(questionID: UUID, meetingID: UUID) async
    public func openThread(_ threadID: UUID, meetingID: UUID) async
    public func newChat(meetingID: UUID)
    public func deleteThread(_ threadID: UUID, meetingID: UUID) async
    public func turnOnLiveTranscript()                // the "Turn On" action

    /// AppCore calls this when a recording stops, so questions waiting for the end start.
    public func recordingDidStop(meetingID: UUID) async
    /// AppCore calls this when it deletes a meeting: its answer stops unsaved, and its chat
    /// state, kept thread and draft, transcript flag and save record go.
    public func meetingWasDeleted(_ meetingID: UUID)
}
```

`AppCore` owns one service (`public let chat: MeetingChatService`), built in `AppCore+Live` from the broker, the store, `modelManager.activeModelURL`, `liveTranscription`, the recording state, and `transcription.jobs`. `AppCore.init` takes it as an optional parameter with a default built from its other services, like `mcpServer`, and `chatDefaults` for that default's `defaults`: the live factory passes `.standard`, tests nil. Availability needs no call when the model, the live setting or the recording changes: `MeetingChatState.availability` reads them from observable state each time. AppCore calls `finalPassWillStart(meetingID:)` in `stopRecording()` as soon as `recording.stop()` returns, `recordingDidStop(meetingID:)` in `finalPassAfterStop` before the final pass starts (a question that waited for Stop then starts), `finalPassDidEnd(meetingID:)` after the pass, and `transcriptWasSaved(meetingID:hasText:)` from `TranscriptionService.onTranscriptSaved`, inside the pass that saves a transcript.

**Restore after relaunch** (added 30 October 2026). `ChatRestore` keeps two UserDefaults keys per meeting, `meetingChat.openThread.<meeting ID>` (the open thread's ID) and `meetingChat.draft.<meeting ID>` (the field's text), and removes a key when there is nothing to keep. `MeetingChatState` writes them from `didSet` on `openThreadID` and `draft`, so every path that changes them keeps them: asking (which clears the draft, and puts it back if the question cannot be saved), New chat, deleting the thread, and a kept thread that `load` finds gone. The thread's messages come from the store as before. A deleted meeting's keys are removed. The card's open state is not kept.

## Internal Design

### Availability

Computed per meeting, in this order (the first match wins):
1. Another meeting is answering → `.answeringElsewhere`.
2. `modelURL()` is nil → `.noModel`.
3. The meeting is recording (`recordingMeetingID() == id`) and `!live.isEnabled` → `.liveTranscriptOff`.
4. Not recording, no preferred transcript, no draft, and `isTranscribing(id)` → `.transcribing`.
5. Not recording, no preferred transcript, no draft → `.noTranscript`.
6. Otherwise `.available`.

"Has a preferred transcript" comes from a cached flag. `load(meetingID:hasTranscript:)` sets it from the caller's reading of the meeting's detail, or, with nil, from `store.meetingDetail(id:)`; `transcriptWasSaved(meetingID:hasText:)` sets it when a pass saves. A preferred transcript with no text (a pass over silence) counts as none (`MeetingChatService.hasTranscriptToAsk`). A live draft counts only when one of its rows has text by the evidence's rule (`ChatEvidence.hasText`), and not once a save has recorded "no text" for the meeting: that save replaces the transcript the draft stood in for.

Phase 10 added: a pass that saves a transcript reports it through `TranscriptionService.onTranscriptSaved(meetingID, segmentTexts)`, and AppCore calls `transcriptWasSaved(meetingID:hasText:)` with `hasTranscriptText(_:)`, the evidence's rule for "has text" (`ChatEvidence.hasText`). A save replaces the preferred transcript, so it sets the flag either way: a save with no text turns chat off for the meeting ("This meeting has no transcript to ask about"), and a later save with text turns it on. Once a save has set a meeting's flag, readings (`load`, the store) leave it: only a pass sets the preferred transcript, so that flag is always current, and a reading taken before the pass saved, with text or without, would be stale. Without a save, a transcript once read stays. Deleting the meeting (`meetingWasDeleted(_:)`) clears its flag and its save record.

### Asking

`ask(meetingID:)`:
1. Trim `state.draft`; return if empty or not `.available`. Clear the draft.
2. Persist the question: `createChatThread(meetingID:firstQuestion:)` when no thread is open (and set `openThreadID`), otherwise `appendChatQuestion(threadID:text:)`. Append its `ChatMessageView` and a streaming answer view with status `.thinking`. Open the card. Set `answeringMeetingID` and `isAnswering`.
3. Start `answerTask = Task { await runAnswer(...) }`. Only one answer task exists at a time.

`runAnswer` (main actor except the awaits):
1. **Evidence:** `record = await evidence(for: meetingID)`. Recording: `live.snapshot(includeTail: true)` → `.live`. Otherwise: `store.meetingDetail(id:)?.preferredTranscript` → `.saved`, else `live.draft(for:)` → `.draft`. Title, date, invitees (calendar attendees' display names) and notes from `meetingDetail`. If the evidence is gone, the answer fails with "There's no transcript to answer from yet."
2. **Earlier turns:** the open thread's question and answer pairs before this question, complete or stopped answers only.
3. **Policy** (recording only): `.waitForStop` → status `.waitingForRecordingToEnd`; the question is parked in `waitingForStop[meetingID]` and the task ends. `recordingDidStop` resumes it with draft evidence.
4. **Lease:** `broker.withLease(model:priority: .interactive, purpose: "chat", keepAlive: policy.keepAlive(isRecording:), onWait:)`. `onWait` maps `.queued(behind: "summary")` → `.waitingForSummary` and `.loadingModel` → `.loadingModel`.
5. Inside the lease:
   - `prompt = try await ChatPromptBuilder.build(..., count: session.countTokens)`.
   - `try await session.reconfigure(contextSize: prompt.contextSize)` (the broker skips it when unchanged).
   - Iterate `session.generateStreaming(messages:options:)`: `.token` appends to the buffer; `.reasoningToken` is ignored; `.done` marks completion.
   - Every `answerFlushInterval`, and at the end, the buffer is copied to the answer view with fresh `ChatAnswerParser.blocks(_, evidenceTimes:)`, and the status becomes `.streaming` after the first token.
6. **Outcome:**
   - `.done` seen → `.complete`.
   - `stopRequested` → `.stopped`, whatever the stream did.
   - `CancellationError`, `LLMServiceError.cancelled` or an end without `.done` while not stopped → failed, "The AI stopped before finishing."
   - `LLMBrokerError.connectionFailed` → failed, "The AI model couldn't start."
   - `ChatPromptError.tooLong` → failed, "This meeting is too long to answer from."
   - Any other error → failed, "Something went wrong while answering."
7. **Save:** `saveChatAnswer(questionID:text:state:errorMessage:basis:)`, with the basis from the prompt. A failed save keeps the view with `isUnsaved = true` and logs the error. Then clear `answeringMeetingID` and refresh availability everywhere.

**`stop()`** sets `stopRequested` and cancels `answerTask`. A question parked for the end of a recording is dropped back to an unanswered question shown as "Interrupted", with Retry.

**`retry`** re-runs steps 3–7 for the stored question, with the earlier turns before it, and saves over the old answer.

### Threads

- `load` reads `chatThreads(meetingID:)`, then the last open thread (from memory, or none on first launch) with `chatThread(id:)`, and maps messages to views. A last message that is a question, with no answer task for it, shows an answer view with state `.interrupted`.
- `openThread` loads that thread. `newChat` clears `openThreadID` and `messages` and closes the card. `deleteThread` deletes it; if it was open, it behaves like `newChat`.
- Opening a meeting's state never touches other meetings' states.

### Resource policy

```swift
public struct ChatResourcePolicy: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case concurrent, waitForStop }
    public var physicalMemory: UInt64
    // 0 after the measurement (research/chat_measurement; Backlog decision B4):
    public var waitForStopMaximumMemory: UInt64 = 0          // no Mac waits
    public var closeAfterAnswerBelowMemory: UInt64 = 24 << 30
    public var idleKeepAlive: Duration = .seconds(180)

    public static func forThisMac() -> ChatResourcePolicy     // ProcessInfo.physicalMemory
    public func mode() -> Mode
    public func keepAlive(isRecording: Bool) -> LLMKeepAlive
}
```

- `mode()`: memory ≤ `waitForStopMaximumMemory` → `.waitForStop`; otherwise `.concurrent`. Outside a recording the mode is irrelevant. With the default of 0 every Mac, 8 GB Macs included, gets `.concurrent`: there is no wait for Stop. Only an explicit limit (the tests, or the chat load driver's `waitForStop` plan mode) gives `.waitForStop`.
- `keepAlive(isRecording:)`: during a recording, on a Mac with less than `closeAfterAnswerBelowMemory`, `.close`, so the AI model's memory is free for the rest of the meeting. Otherwise `.keepOpen(idleKeepAlive)`.
- The live transcript is never paused for chat. Phase 7 built the [live hold](live_hold.md) and a third mode, `.holdLiveTranscript`, switched off on every Mac; Backlog decision B5 removed both. Answers run beside the live transcript on every Mac.

### Logging

`Logger(subsystem: "net.scosman.biscotti", category: "meeting-chat")`: ask, policy mode, lease wait, prompt token count and context size, `isPartial`, outcome and duration. Never question or answer text.

## Dependencies

- `DataStore`, `Intelligence` (`LLMBroker`, `LLMBrokerError`), `LiveTranscriptionService` (snapshot, draft, `isEnabled`, `setEnabled`), `LiveTranscriptModel`, `LocalLLM`, and the `MeetingChat` context files.
- Used by `AppCore`, `MeetingChatUI`, `RecordingUI` and `MeetingDetailUI`.

## Test Plan (`MeetingChatTests/MeetingChatServiceTests.swift`, through `CoreFixture` with `ScriptedLLMOpener`)

Availability:
- `noModelWhenNoneDownloaded`, `liveOffWhileRecording`, `transcribingWithoutDraft`, `noTranscriptAfterFailedPass`, `availableWithSavedTranscript`, `availableWithDraftOnly`, `answeringElsewhereBlocksOthers`.

Asking:
- `firstQuestionCreatesThread`: the thread and question are stored before the model answers.
- `streamedAnswerIsSavedComplete`: scripted tokens produce one stored answer, `.complete`, with `.transcript(id:)` basis.
- `liveAnswerUsesSnapshot`: during a recording, the prompt holds the snapshot's rows and the basis is `.live(through:)`.
- `draftAnswerUsesDraft`: after Stop and before the final pass, the basis is `.draft` and the footer says "Based on the draft transcript".
- `flushThrottlesUpdates`: 200 tokens in 100 ms produce no more than about 3 view updates, and the final text is complete.
- `statusShowsLoadingThenThinking`: a slow open reports `.loadingModel`, then `.thinking`, then `.streaming`.
- `waitsBehindSummary`: with a background lease running, the status is `.waitingForSummary` until it ends.
- `stopSavesStopped`: Stop mid-stream saves the partial text as `.stopped`.
- `endWithoutDoneFails`: a stream that ends without `.done` saves `.failed("The AI stopped before finishing.")`.
- `openFailureFails`: a failed model open saves `.failed("The AI model couldn't start.")`.
- `tooLongFails`: a counter that always overflows saves `.failed("This meeting is too long to answer from.")`.
- `saveFailureMarksUnsaved`: a store that throws on save leaves the answer shown with `isUnsaved`.
- `retryReplacesFailedAnswer`: Retry after a failure stores one complete answer for that question.
- `interruptedAfterRelaunch`: a stored thread ending in a question loads with an `.interrupted` answer.
- `earlierTurnsInPrompt`: the second question's prompt contains the first question and answer; a failed first answer is left out.

Threads:
- `newChatClearsOpenThread`, `openThreadLoadsMessages`, `deleteOpenThreadActsLikeNewChat`, `threadsNewestFirst`, `lastOpenThreadRemembered`.

Restore (`MeetingChatRestoreTests`, a relaunch is a second service on the same store and defaults suite):
- `relaunchRestoresThreadAndDraft`: the open thread and the draft come back, the card closed; `load` shows the thread's messages.
- `sendingClearsKeptDraft`: a sent question clears the kept draft; one that could not be sent stays kept.
- `meetingsKeepTheirOwn`: two meetings keep separate threads and drafts.
- `closedThreadsAreNotRestored`: New chat, Delete This Chat… and deleting the meeting leave nothing to restore.
- `missingKeptThreadIsForgotten`: a kept thread gone from the store is forgotten on `load`.
- `noDefaultsKeepsNothing`.

Cited line (`MeetingChatCitedLineTests`):
- `savedTranscriptLine`: a chip's time gives the saved line starting there, and a time inside a line gives that line.
- `liveTranscriptLine`: during the recording, the live row with its unsettled tail.
- `noLine`: no transcript, or a time before the first line, gives nil.

Policy:
- `policyDefaultsToConcurrent`: 8, 16 and 64 GB all give `.concurrent` with the defaults; with `waitForStopMaximumMemory` = 8 GB, 8 GB gives `.waitForStop` and 16 GB `.concurrent`.
- `eightGigabyteMacAnswersDuringRecording`: with the defaults, an 8 GB Mac answers a question asked during a recording from the live snapshot, without waiting for Stop.
- `liveTranscriptNotPausedWhileAnswering`: during a recording, the fake live engine keeps receiving chunks while an answer streams.
- `waitForStopParksQuestion`: in wait mode, the question waits with `.waitingForRecordingToEnd` and is answered from the draft after `recordingDidStop`.
- `closeAfterAnswerWhileRecordingOnSmallMac`: during a recording, the lease's keep-alive is `.close` on 16 GB and `.keepOpen(180 s)` on 32 GB; outside a recording it is `.keepOpen(180 s)` on both.
