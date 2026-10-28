---
status: complete
---

# Meeting chat

Design and build the "chat with the meeting" feature we discussed before, inspired by Granola's chat. The user asks Biscotti a question about a meeting and gets an answer from the local LLM, based on what was said.

The chat with the meeting is a separate feature branch from the live transcript, and it depends on the live transcripts to be able to do it: during a recording, questions are answered from the live transcript.

## Scope decisions (27 October 2026)

- You can ask while recording and on saved meetings.
- Chats persist. A meeting keeps as many chat threads as the user creates in it.
- Questions across meetings are a later project.
- Keep Copy, and times in an answer that open the transcript at that moment.
- Leave out preset prompts, "Say more", thumbs up and down, dictation, a model picker and a full-window chat. Attachments are left out for now and earmarked as a future feature.
- Answers use the local model already chosen in Settings, the one that writes summaries.
- Chat should work during a recording. Measure whether it fits beside the live transcript, especially on Macs with 8 GB of memory, before deciding what happens there.
- Built on the live transcript branch. No hard limit on the PR's size.

These decisions replace the first design sketch below where they differ.

## Inputs

- **Granola's chat:** a screen recording of Granola, summarized in [research/granola_video](research/granola_video/research_summary.md).
- **The first design sketch** (22 October 2026, written when chat was split out of the live transcript design, kept outside the repo). Its main points:
  - Each answer comes from a frozen snapshot of the live transcript and says how far into the meeting it reaches ("Based on transcript through 12:34"). Times in an answer open the transcript drawer at that moment.
  - The question field sits to the right of the drawer's round button, and the bottom of the screen is one slot shared by the drawer and the chat.
  - Questions are small right-aligned bubbles, and answers are full-width text, so they never look like transcript bubbles.
  - The answer runs on the existing local LLM stack (`LLMConnection.generateStreaming`, `ContextSizing`), in a new side-effect-free service, not `MeetingAnalyzer`.
  - Transcript text is evidence, never an instruction to the model. The only speaker labels during a recording are "You" and "Others". Long meetings that do not fit the context need timestamped retrieval.
  - The first version saves no chat history. It leaves out Granola's model picker, attachments, dictation, preset prompts and feedback buttons.
  - The same snapshot could back a read-only live tool in the MCP server.
  - A chat answer must not slow the live transcript. On Macs with 8 GB or less, measurements decide whether chat runs during a recording.
- **What `live_transcript` already provides** for this project: `snapshot(includeTail:)` on `LiveTranscriptionService`, the free space to the right of the drawer's round button, and a request to open the drawer at a given time.
- **Model study** (`specs/research/model_options/README.md` on `codex/model-options`): for finding the right part of a long meeting, keyword search plus a text embedder over the transcript works. Keyword overlap found the right 20 s window first 79% of the time. EmbeddingGemma 2's text side is a good on-device embedder, and its audio side is not needed.
