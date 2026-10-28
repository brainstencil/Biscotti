---
status: complete
---

# Phase 4: MeetingChatService

## Overview

Builds `MeetingChatService` ([meeting_chat_service](../components/meeting_chat_service.md)), the chat's source of truth while the app runs: availability per meeting, asking, Stop, Retry, threads, recovery of answers interrupted by a quit, and the resource policy during a recording. It persists through `DataStore` (phase 1), answers through `LLMBroker` (phase 2) with prompts from `ChatPromptBuilder` (phase 3), and is wired into `AppCore` and `CoreFixture`. A `MeetingChatAITests` suite joins `make test-ai`.

It also applies the manager's decisions from the review of phases 1 to 3 (`.specs_skill_state/phase4-brief.md`): an optional basis, stored cited times, earlier turns from complete or stopped answers only, interrupted questions anywhere in a thread, a shared summary purpose, closing the model at the start of a recording on small Macs, and public live-text access.

## Steps

1. **Storage (decisions 1 and 2).**
   - `ChatMessage`: add `citedTimesData = Data()` (JSON, the `AppSettings.customVocabularyData` pattern, because SwiftData cannot read arrays back from an on-disk store in an SPM module) and `@Transient public var citedTimes: [TimeInterval]`. Additive V1 change, no migration stage.
   - `ChatMessageData`: add `citedTimes: [TimeInterval]` (default `[]`), mapped in `mapChatThread`.
   - `saveChatAnswer(questionID:text:state:errorMessage:basis: ChatBasis?, citedTimes: [TimeInterval] = [])`. A retry replaces the cited times too.

2. **MeetingChat context changes.**
   - `ChatTypes.swift`: `public var basis: ChatBasis` on `ChatTranscript` (moved from `PromptParts`, which now uses it); `ChatPrompt.promptTokens` for logging.
   - `ChatPromptBuilder.swift`: replace the comment at lines 29–30 with the text from decision 3.
   - `ChatAnswerParser.citedTimes(in: [ChatBlock]) -> [TimeInterval]`: the distinct `ChatTimeAttribute` values, ascending.

3. **Broker (decision 5 and cleanups).**
   - `BrokeredLLMRunner.defaultPurpose = "summary"`, used as the init's default.
   - `LLMBroker`: log the failed open's `error.localizedDescription` (private); state the unfinished-stream rule as the rule in `dropReason`'s comment.

4. **Package.** `MeetingChat` gains `Intelligence` and `LiveTranscriptionService`. `MeetingChatTests` gains `BiscottiTestSupport`, `AppCore`, `Intelligence`, `LiveTranscriptionService` and `LiveTranscription`. `AppCore` and `BiscottiTestSupport` gain `MeetingChat`. New test target `MeetingChatAITests` (`MeetingChat`, `DataStore`, `LocalLLM`).

5. **`MeetingChat/ChatStoring.swift`**: `public protocol ChatStoring: Sendable` with the store calls chat makes (`meetingDetail(id:)`, `chatThreads(meetingID:)`, `chatThread(id:)`, `createChatThread`, `appendChatQuestion`, `saveChatAnswer`, `deleteChatThread`), and `extension DataStore: ChatStoring`. The service takes `any ChatStoring`, so a test store can fail a save.

6. **`MeetingChat/ChatResourcePolicy.swift`**: the struct as specified (`physicalMemory`, `waitForStopMaximumMemory = 0`, `closeAfterAnswerBelowMemory = 24 GiB`, `idleKeepAlive = 180 s`), `forThisMac()`, `mode()` and `keepAlive(isRecording:)`.

7. **`MeetingChat/ChatErrorText.swift`**: the five failure sentences from the component doc.

8. **`MeetingChat/MeetingChatState.swift`**: `ChatAvailability`, `ChatAnswerStatus`, `ChatMessageView` (public memberwise init, for previews in phase 8) and `MeetingChatState`. `availability` is computed on each read from the service, whose inputs (`modelURL`, `recordingMeetingID`, `isTranscribing`, `live.isEnabled`, drafts, the answering meeting and the cached transcript flags) are all observable, so SwiftUI tracks it without refresh calls.

9. **`MeetingChat/MeetingChatService.swift`** (split into `+Answer` and `+Threads` extensions to stay under the lint limits):
   - `init(store: any ChatStoring, broker:, modelURL:, live:, recordingMeetingID:, isTranscribing:, policy: = .forThisMac(), answerFlushInterval: = 50 ms, clock: any Clock<Duration> = ContinuousClock())`. The clock times the flush throttle.
   - `state(for:)`, `load(meetingID:)`, `refreshAvailability() async` (re-reads the transcript flag of every known meeting), `ask`, `stop`, `retry`, `openThread`, `newChat`, `deleteThread`, `turnOnLiveTranscript() async` (calls `onTurnOnLiveTranscript`, which AppCore sets, or `live.setEnabled(true)`), `recordingDidStart() async` (decision 6: `broker.closeWhenIdle()` when the policy closes after answers during a recording), `recordingDidStop(meetingID:) async`.
   - One `AnswerRun` (main-actor class) at a time: meeting, thread, question, earlier turns, the answer view, the text buffer, the prompt, the reader task, `stopRequested`.
   - Asking: reserve the answer slot before the first await; persist the question (create or append); append the question view and a `.streaming(.thinking)` answer view; open the card; start the task. A failed question write restores the draft.
   - Answering: during any recording, `.waitForStop` parks the run (`.waitingForRecordingToEnd`). Otherwise gather evidence (live snapshot while this meeting records, else the preferred transcript, else the draft; title, date, organizer and attendee names, notes); an empty transcript fails with "There's no transcript to answer from yet.". Lease at `.interactive`, purpose `"chat"`, keep-alive from the policy; `onWait` binds to a constant and maps `.queued(behind: BrokeredLLMRunner.defaultPurpose)` → `.waitingForSummary`, `.loadingModel` → `.loadingModel`, applied only until the lease starts. In the lease: status `.thinking`, build the prompt with `session.countTokens`, reconfigure, start the stream.
   - Reading: a detached reader task pulls the stream to its end and forwards events through an `AsyncThrowingStream`; the main-actor consumer appends tokens, ignores reasoning tokens, notes `.done`, and flushes the view at the first token, then at most every `answerFlushInterval` of the clock, then at the end. The reader's only suspension point is the pull, so Stop cancels it inside a pull and the connection survives.
   - Stop: parked → the question shows `.interrupted` (nothing saved); reading → cancel the reader; before that → cancel the answer task.
   - Outcome: `.done` → complete; else Stop → stopped; then the component doc's error mapping. Save with the prompt's basis (nil before a prompt exists) and the answer's cited times; a failed save sets `isUnsaved`. The saved answer view takes the stored ID. Clear the slot and reload the thread list.
   - Retry: re-runs the question with the earlier turns before it and replaces its answer view in place.
   - Earlier turns: question and answer pairs before the question whose answer view is `.complete` or `.stopped` (decisions 3 and 4).
   - Threads: `load` reads the thread list and the transcript flag, then reloads the open thread unless it holds the running answer. Stored messages map to views; a question with no answer at `index + 1` gets an `.interrupted` answer view (decision 4); stored answers parse with their `citedTimes` as evidence (decision 2); the footer is "Based on the transcript through m:ss", "Based on the draft transcript" or nil. A running answer's view overlays its question's answer slot when its thread is shown. `newChat` clears the open thread and closes the card; `deleteThread` discards a running answer in that thread, deletes, and acts like `newChat` if it was open. A per-meeting load token drops stale loads.
   - Logging (`meeting-chat`): ask, policy mode, lease wait, prompt tokens, context size, `isPartial`, outcome and duration; never question or answer text.

10. **AppCore wiring.**
    - `AppCore+Chat.swift`: a `MeetingChatService` convenience init on `DataStore`, `LLMBroker`, `ModelManager`, `LiveTranscriptionService`, `RecordingController` and `TranscriptionService`; AppCore's `turnOnLiveTranscriptForChat()` (persist the setting, `liveTranscription.setEnabled(true)`, prepare models).
    - `AppCore`: `public let chat: MeetingChatService`; `chat: MeetingChatService? = nil` as the init's last parameter, defaulting to the convenience init; set `chat.onTurnOnLiveTranscript`.
    - `completeRecordingStartup` calls `chat.recordingDidStart()` once the recording runs. `finalPassAfterStop` calls `chat.recordingDidStop(meetingID:)` before the final pass and `chat.refreshAvailability()` after it.

11. **Test support.**
    - `makeCoreFixture(chatPolicy:chatClock:)`, the policy defaulting to `ChatResourcePolicy(physicalMemory: hardwareRAMBytes)`; `CoreFixture.chat`.
    - `FailingChatStore` (wraps a `DataStore`, can throw on answer saves).
    - `ScriptedStream` and `ScriptedLLMOpener` sleep on an injectable clock; `TestClock.pendingSleepCount`; `FastForwardClock` (a sleep returns at once and moves time to its deadline); `Latch` moves from `LLMBrokerTests` to `BiscottiTestSupport`.

12. **AI test.** `Tests/MeetingChatAITests/MeetingChatAITests.swift`, gated on `BISCOTTI_RUN_AI_TESTS=1`: the real model (in-process, `LLM_MODEL_PATH` or the default 12B path) answers fixed questions about a fixture transcript through `ChatPromptBuilder`; at least 90% of cited times must become chips. `make test-ai` runs it.

## Tests

`MeetingChatTests/MeetingChatServiceTests.swift` (and companion files), through `CoreFixture`'s store, broker and `ScriptedLLMOpener`, with the service built on test closures:

- Availability: `noModelWhenNoneDownloaded`, `liveOffWhileRecording`, `transcribingWithoutDraft`, `noTranscriptAfterFailedPass`, `availableWithSavedTranscript`, `availableWithDraftOnly`, `answeringElsewhereBlocksOthers`.
- Asking: `firstQuestionCreatesThread`, `streamedAnswerIsSavedComplete`, `liveAnswerUsesSnapshot`, `draftAnswerUsesDraft`, `flushThrottlesUpdates` (fast-forward clock), `statusShowsLoadingThenThinking` (test clock), `waitsBehindSummary`, `stopSavesStopped` (also: the next question reuses the connection, `openCount == 1`), `stopWhileQueuedSavesStoppedWithoutBasis`, `endWithoutDoneFails`, `openFailureFails` (no basis), `tooLongFails`, `noEvidenceFails`, `saveFailureMarksUnsaved`, `retryReplacesFailedAnswer`, `interruptedAfterRelaunch`, `interruptedQuestionInsideThread`, `earlierTurnsInPrompt` (failed and interrupted turns left out), `reopenedAnswerKeepsChips`, `storedAnswerWithoutCitedTimesIsPlain`.
- Threads: `newChatClearsOpenThread`, `openThreadLoadsMessages`, `deleteOpenThreadActsLikeNewChat`, `threadsNewestFirst`, `lastOpenThreadRemembered`.
- Policy: `policyDefaultsToConcurrent`, `liveTranscriptNotPausedWhileAnswering`, `waitForStopParksQuestion`, `stopDropsParkedQuestion`, `closeAfterAnswerWhileRecordingOnSmallMac`.
- `ChatStoreTests`: `citedTimesRoundTrip` (and replaced on retry), `answerWithoutBasis`.
- `AppCoreChatTests`: AppCore builds `chat`; starting a recording closes a kept-open summary connection on a 16 GB Mac and not on a 32 GB one (decision 6); Stop resumes a parked question from the draft; `turnOnLiveTranscript` persists the setting and turns live on.
- `ScriptedLLMTests`: token delays and open delays follow the injected clock.
