---
status: complete
---

# Phase 8: MeetingChatUI

## Overview

Builds the chat's SwiftUI components from the [UI design](../ui_design.md) and [chat_ui](../components/chat_ui.md): the question field in every state, the chat card (header with History menu, New chat and close; the message list; the footer field and footnote), the answer renderer with time chips, and previews of every state. The views observe `MeetingChatState` and call `MeetingChatService` as phase 4 built them. Placement on the recording screen and the meeting page, the transcript highlight and ⌘J are phase 9.

Shared pieces: `HoverHighlight` moves to `DesignSystem`, `TypingDots` becomes public, and `Tokens` gains the chat tokens.

The manager's notes apply: the UI text never promises that Turn On catches up from the start of the recording (B1); an answer with no basis shows no basis line; reopened answers draw the blocks the service parsed with their stored cited times.

## Steps

1. **DesignSystem.**
   - New `HoverHighlight.swift`: `public struct HoverHighlight<Content: View>` with `public init(isPressed: Bool, @ViewBuilder content: () -> Content)`, moved from `RecordingUI/LanguageMenu.swift`, which now uses it from `DesignSystem`.
   - `Tokens`: `chatFieldHeight = 40`, `chatRoundButton = 28`, `chatTurnSpacing = 26`, `chatAnswerSpacing = 16`, `chatLineSpacing`. `chatLineSpacing` gives the UI design's 1.45 line height at 14 pt: SwiftUI's `lineSpacing` adds to the font's own line height, so it is `14 × 1.45` minus the system font's line height at 14 pt (about 3.5 pt), not the component doc's `14 × 0.45` (6.3 pt, a 1.65 line height).

2. **TranscriptUI.** `TypingDots` becomes `public` with a `public init()`.

3. **MeetingChat preview support** (`MeetingChatState+Preview.swift`, `#if DEBUG`):
   - `MeetingChatState.preview(meetingID:availability:threads:openThreadID:messages:isAnswering:isCardOpen:draft:)`: a standalone state with a fixed availability, for previews.
   - `MeetingChatService.preview()`: a service on an in-memory store, a model opener that fails, and an inert live transcript, so preview views have something to call.

4. **Package.** New product and target `MeetingChatUI` (`MeetingChat`, `DataStore`, `DesignSystem`, `Formatting`, `TranscriptUI`, `warningsAsErrors`) and test target `MeetingChatUITests` (`MeetingChatUI`, `MeetingChat`, `DataStore`). `RecordingUI` and `MeetingDetailUI` gain it in phase 9.

5. **`MeetingChatUI/ChatPlacement.swift`**: `public enum ChatPlacement { recordingRow, recordingCard, meetingPage, meetingCard }` with `isInCard` (no shadow on the field), and `public enum ChatFieldAction { openSettings, turnOnLiveTranscript, openCard }`.

6. **`ChatFieldPresentation`** (internal, `Equatable`):
   - `placeholder`, `button: ButtonKind` (`.sendDisabled`, `.send`, `.stop`, `.none`), `isEnabled`, `action: ActionButton?` (`title`, `ChatFieldAction`).
   - `make(availability:hasThread:isCardOpen:isAnswering:hasText:)`, and `make(state:)` reading the state (`hasText` from the trimmed draft).
   - An answer in this meeting wins over availability, so Stop stays reachable: empty placeholder, `.stop`.
   - Unavailable: the reason as the placeholder, `.none`, not enabled; "Open Settings" for `.noModel`, "Turn On" for `.liveTranscriptOff`.
   - Otherwise "Ask about this meeting" with no open thread, "Continue chat" with a thread and the card closed, "Ask a follow-up" with the card open; `.send` with text, else `.sendDisabled`.
   - `characterCount(length:locale:) -> String?`: "1,950 / 2,000" from 1,800 characters.

7. **`ChatQuestionField`** (public): `init(state:service:placement:focus:onAction:)`.
   - Enabled: a 40 pt pill (`cardFill`, 1 pt `cardStroke`, radius 20, the toggle's soft shadow outside cards), a vertical `TextField` bound to `state.draft` with `selection`, 14 pt, `lineLimit(1...5)`, 16 pt leading padding, the count from 1,800, and the 28 pt round button 6 pt from the right end (disabled send: `neutralChip` with an `inkTertiary` arrow; send: `accentFill` with a white arrow; stop: an `ink` circle with a 9 pt white rounded square).
   - Keys: Return sends (no-op while answering); Shift-Return inserts a line break at the selection; Esc stops a running answer, else closes the card; `onChange` trims the draft to 2,000 characters.
   - Clicking the text area of a "Continue chat" field calls `onAction(.openCard)` and focuses.
   - Unavailable: `neutralChip` fill, no shadow, the reason in 13.5 pt `inkSecondary`, and the action as a small bordered button (`cardFill`, `cardStroke`, `chipRadius`, 12.5 pt sage medium).
   - VoiceOver: "Ask about this meeting", "Send question", "Stop answer".

8. **`ChatHistoryPresentation`** (internal, `Equatable`): items (`id`, `title`, `time`, `isOpen`) newest first by `updatedAt`; time "5:21 PM" today, "Oct 26" earlier (`Date.FormatStyle`); `make(threads:openThreadID:now:calendar:locale:)` and `make(state:now:)`.

9. **`ChatCard`** (public): `init(state:service:placement:focus:onTime:onAction:footerLeading:)`, plus an init without `footerLeading`. `cardFill`, 0.5 pt `cardStroke`, `drawerRadius`, the drawer's shadows. Esc (`onExitCommand`) stops an answer or closes the card.
   - `ChatCardHeader`: 43.5 pt plus a `hairline`. History `Menu` (clock-with-arrow and chevron, `HoverHighlight` pressed state; threads as checked toggles with the time as a subtitle, then "New Chat" and "Delete This Chat…" with its alert), New chat (`square.and.pencil`, ⌘N; closes the card and focuses the field), close (minus). VoiceOver: "Chat history, [thread name]", "New chat", "Close chat".
   - `ChatMessageList`: `ScrollView` + `LazyVStack`, 24 pt sides, anchored to the bottom for its first offset and for short content; follows new text while at the bottom, stops when the user scrolls up, and shows a round down-arrow button at the bottom center that jumps back.
   - `ChatQuestionBubble`: right-aligned, at most 72% of the list width, `cardFill`, 1 pt `cardStroke`, `bubbleRadius`, 7 × 12 pt padding, 14 pt `ink`.
   - Footer: `.recordingCard` holds `footerLeading` then the field, with the footnote just under the card; `.meetingCard` holds the field and the footnote under it.
   - `ChatFootnote` (public): "Answers come from the on-device AI and can be wrong.", 10.5 pt `inkTertiary`, centered.

10. **Answers.**
    - `ChatAnswerView`: the status line before the first word (`ProgressView` small and the status text), else the blocks (8 pt apart) with `TypingDots` while streaming; the footer row 8 pt below once finished. Announces a finished answer once, and status changes.
    - Blocks: paragraphs and headings (semibold) are 14 pt `Text` with `chatLineSpacing`; bullets are a 4 pt `inkTertiary` dot with an 18 pt indent per level; numbered items show "N." in `inkSecondary`.
    - `ChatAnswerText`: splits a block's text into segments; chip runs get JetBrains Mono 11.5, sage, a `biscotti-chat-time:<seconds>` link and `ChatChipAttribute`; other links are removed (answer text is model output). The chip's padding is 5 pt of kerning on its last character and on the character before it, so the wash never covers neighbouring text. `ChatChipRenderer: TextRenderer` fills a 5 pt-radius `accentWashSoft` rounded rectangle behind each chip (its runs joined per line), then draws the text. `openURL` turns a chip link into `onTime`. Each block offers "Go to m:ss in the transcript" accessibility actions.
    - `ChatAnswerFooterPresentation`: copy shown when the answer has text; "Stopped", "Interrupted" or the red error; the basis line from `message.footer` (none when nil); Retry for failed and interrupted answers; "Couldn't save this answer" when unsaved.
    - `ChatAnswerCopy.plainText(_ blocks:)`: Markdown markers removed, chips as their time, bullets "• " indented two spaces per level, numbered "N. ", paragraphs separated by a blank line. The copy button writes it to the pasteboard and shows "Copied" for 1.5 s.
    - Status text: "Loading the AI model…", "Waiting for the summary to finish…", "Answers when the recording stops", "Thinking…".

11. **Previews** (`ChatPreviews.swift`, `#if DEBUG`): the field in every state and placement (no thread, continue chat, follow-up, text typed, count, answering, each unavailable reason); the card in both placements with status lines, streaming, complete with chips, stopped, failed, interrupted and unsaved answers, an empty thread, and the History menu with threads; dark mode for the field and the card.

## Tests

`MeetingChatUITests`:
- `fieldPlaceholders`: no thread, card closed with a thread, and card open give "Ask about this meeting", "Continue chat" and "Ask a follow-up".
- `fieldButtons`: empty → `.sendDisabled`; text → `.send`; answering → `.stop`; unavailable → `.none`.
- `answeringWinsOverAvailability`: an answer in this meeting shows Stop even when the meeting turned unavailable.
- `unavailableFieldTexts`: each `ChatAvailability` maps to the UI design's text and action ("Open Settings", "Turn On", none), not enabled.
- `fieldFromState`: `make(state:)` reads availability, the open thread, the card, answering and the trimmed draft.
- `characterCountAppearsAt1800`: nil at 1,799, "1,800 / 2,000" at 1,800, "2,000 / 2,000" at 2,000.
- `historyItemsNewestFirst`: titles in `updatedAt` order, the open thread's checkmark, "5:21 PM" today and "Oct 26" earlier.
- `copyTextStripsMarkdown`: "**A base** it lives in [0:34]" copies as "A base it lives in 0:34"; lists, numbers and headings copy as plain text.
- `answerFooters`: complete with and without a basis, stopped, failed with and without text, interrupted, unsaved, and an answer still streaming.
- `statusTexts`: each `ChatAnswerStatus` before the first word.
- `chipSegments`: a cited time becomes a chip segment with its link and mono font, the character before it is kerned, a plain time stays plain, and a Markdown link in the answer loses its link.
- `timeLinksRoundTrip`: `biscotti-chat-time:` links parse back to their seconds; other URLs give nil.
