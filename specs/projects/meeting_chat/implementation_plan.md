---
status: complete
---

# Implementation Plan: Meeting Chat

Phases 1 to 4 build chat without any UI. Phases 5 and 6 measure it on this Mac and end with your review of the resource policy. Phase 7 runs only if that measurement asks for the pause. Phases 8 to 10 build the UI and validate it on hardware. Each phase's details are in the component named in brackets.

No phase changes `Packages/Transcription`, `AudioCapture`, `LocalLLM` or `MCPServer`, so no manual tests are reset, except in phase 7 if you choose the watchdog remedy.

## Phases

- [x] Phase 1: Chat storage: `ChatThread` and `ChatMessage` models, the `Meeting.chatThreads` cascade, read models, write methods, and the test that opens a store made before the chat models [chat_store]
- [x] Phase 2: `LLMBroker` in `Intelligence`: leases, priorities, keep-alive and idle close, `BrokeredLLMRunner` and `LiveLLMConnectionOpener`; `Intelligence` moves onto the broker in `AppCore`, `PreviewAppCore` and `CoreFixture` [llm_broker]
- [x] Phase 3: The `MeetingChat` target and `ChatContextBuilder`: evidence lines, the prompt, fitting and passage selection for long meetings, and answer parsing with citation checks [chat_context]
- [x] Phase 4: `MeetingChatService`: availability, asking, Stop, Retry, threads, recovery of answers interrupted by a quit, the resource policy, and the `AppCore` and `CoreFixture` wiring; a `MeetingChatAITests` suite added to `make test-ai` [meeting_chat_service, chat_context]
- [x] Phase 5: Measurement tools: the DEBUG `ChatLoadDriver`, the three plans, and `Tools/chat_bench/analyze.py`, with their tests [chat_measurement]
- [x] Phase 6: Run the measurement in Biscotti Dev: baseline, concurrent and after-stop with Gemma 4 E2B, concurrent with Gemma 4 12B, and concurrent with Low Power Mode on (you turn it on). You also run `make test-ai`. Write `research/chat_measurement/README.md`, set `ChatResourcePolicy`'s thresholds, and stop for your review. Starting the recordings needs your go-ahead [chat_measurement]
- [ ] Phase 7 (only if phase 6 trips the contention rule): build the live hold and the `.holdLiveTranscript` mode, re-run `concurrent` with it, and measure the other remedy, a higher watchdog limit while an answer runs; you choose between them. The watchdog remedy changes `Packages/Transcription`, so it marks the `tx_*` manual tests not-run [live_hold, chat_measurement]
- [x] Phase 8: `MeetingChatUI`: the question field, chat card, History menu, answer renderer and time chips; `HoverHighlight` moves to `DesignSystem`, `TypingDots` becomes public, the new tokens, and previews of every state in the UI design [chat_ui]
- [x] Phase 9: Placement: the recording screen's bottom slot and "Back to chat", the transcript highlight, the meeting page's field band and card, and the ⌘J command [chat_ui]
- [ ] Phase 10: Hardware validation in Biscotti Dev: asking during a recording and on saved meetings, time links on both screens, Stop, Retry, quitting mid-answer, VoiceOver and keyboard use, and a visual review against the v2 mockups in light and dark mode [chat_ui, meeting_chat_service]
- [ ] **Phase 11: Backlog.** Decide each open backlog item with the user, then close or dismiss them all.

The demo video and the pull request follow phase 10, outside this plan.
