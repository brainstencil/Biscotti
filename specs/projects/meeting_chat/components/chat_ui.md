---
status: complete
---

# Component: Chat UI

## Purpose and Scope

The SwiftUI views from the [UI design](../ui_design.md) and their placement on the recording screen and the saved meeting page. Views observe `MeetingChatState` and call `MeetingChatService`; they hold no chat logic beyond presentation.

Not its job: chat behaviour ([meeting_chat_service](meeting_chat_service.md)) or answer parsing ([chat_context](chat_context.md)).

New module `MeetingChatUI`, plus changes in `RecordingUI`, `MeetingDetailUI`, `TranscriptUI`, `DesignSystem`, `AppShellUI` and `App`.

## Shared pieces moved or opened

- `HoverHighlight` moves from `RecordingUI/LanguageMenu.swift` to `DesignSystem/HoverHighlight.swift` and becomes public; `LanguageMenu` imports it from there.
- `TypingDots` in `TranscriptUI` becomes public.
- `Tokens` gains `chatFieldHeight = 40`, `chatRoundButton = 28`, `chatTurnSpacing = 26`, `chatAnswerSpacing = 16` and `chatLineSpacing` (14 pt × 0.45). Every other value in the UI design is an existing token.

## MeetingChatUI Views

```swift
public enum ChatPlacement { case recordingRow, recordingCard, meetingPage, meetingCard }

/// The question field in every state. Placement decides shadow and width rules.
public struct ChatQuestionField: View {
    public init(state: MeetingChatState, service: MeetingChatService, placement: ChatPlacement,
                focus: FocusState<Bool>.Binding, onAction: @escaping (ChatFieldAction) -> Void)
}
public enum ChatFieldAction { case openSettings, turnOnLiveTranscript, openCard }

/// The card: header, message list, and (in card placements) the field and footnote.
public struct ChatCard<Leading: View>: View {
    public init(state: MeetingChatState, service: MeetingChatService, placement: ChatPlacement,
                onTime: @escaping (TimeInterval) -> Void,
                @ViewBuilder footerLeading: () -> Leading)   // the level meter on the recording screen
}
```

Internal views: `ChatCardHeader` (History button with `Menu`, New chat, close), `ChatMessageList` (a `ScrollView` + `LazyVStack` anchored to the bottom with `.defaultScrollAnchor(.bottom)`, following new text unless the user scrolled up, plus the round down-arrow button), `ChatQuestionBubble`, `ChatAnswerView`, `ChatAnswerFooter`, `ChatStatusLine`, `ChatFootnote`.

**Presentation structs** keep the logic testable without views:

```swift
struct ChatFieldPresentation: Equatable {
    let placeholder: String        // per the UI design's state tables
    let button: ButtonKind         // .sendDisabled, .send, .stop, .none
    let isEnabled: Bool
    let action: (title: String, ChatFieldAction)?
    static func make(state: MeetingChatState, hasText: Bool) -> Self
}
struct ChatHistoryPresentation: Equatable {
    let items: [(id: UUID, title: String, time: String, isOpen: Bool)]
    static func make(state: MeetingChatState, now: Date, calendar: Calendar) -> Self
}
```

`time` is "5:21 PM" for today and "Oct 26" for earlier days, from `Formatting`'s existing time and date styles.

**Answer rendering.** `ChatAnswerView` draws `[ChatBlock]`:
- Paragraphs and headings are `Text(attributed)`, 14 pt, line spacing `chatLineSpacing`, 8 pt apart. Headings use 14 pt semibold.
- Bullets are an `HStack(alignment: .firstTextBaseline)` of a 4 pt `inkTertiary` circle and the text, indented 18 pt per level. Numbered items show "N." in `inkSecondary`.
- **Time chips:** before rendering, runs carrying `ChatTimeAttribute` get JetBrains Mono 11.5 (`Font.biscottiMono(11.5)`), sage foreground, a `.link` to `biscotti-chat-time:<seconds>`, and a custom `ChatChipAttribute: TextAttribute`. The block's `Text` uses `.textRenderer(ChatChipRenderer())`, a `TextRenderer` (macOS 15) that, for each run with `ChatChipAttribute`, fills a rounded rectangle (radius 5, `accentWashSoft`, 5 pt horizontal and 1 pt vertical outset) behind the run's typographic bounds, then draws the text. `.environment(\.openURL, OpenURLAction { url in … onTime(seconds); return .handled })` turns a click into `onTime`.
- Streaming dots (`TypingDots`) follow the last block while the state is `.streaming`.

**Footer row.** A 14 pt copy icon button (`doc.on.doc`, `inkTertiary`, `HoverHighlight`). It copies the answer's plain text (Markdown markers removed, chips as their time) and shows "Copied" for 1.5 s. Then the footer text, 11.5 pt `inkSecondary`. "Stopped" shows for a stopped answer; a failed answer shows its error in `signalRedText` and a "Retry" button; `isUnsaved` adds "Couldn't save this answer".

**Status line.** `ProgressView().controlSize(.small)` and the status text: "Loading the AI model…", "Waiting for the summary to finish…", "Answers when the recording stops", "Thinking…".

**Keys.** The field is a `TextField(axis: .vertical)` with `lineLimit(1...5)`.
- Return without Shift sends (`.onKeyPress(.return)` returns `.handled` unless Shift is held).
- Esc stops a running answer or closes the card.
- An `onChange` trims the text to 2,000 characters; the count shows from 1,800.
- The card's New chat button has `.keyboardShortcut("n")`, so ⌘N works while the card is shown.

## Recording screen (`RecordingUI`)

- `RecordingViewModel` gains `chat: MeetingChatState` and a computed `bottomSlot`: `.chat` if `chat.isCardOpen`, else `.transcript` if the drawer is expanded, else `.collapsed`. Its actions:
  - `openChat()` sets `isCardOpen = true` and collapses the drawer.
  - `toggleDrawer()` closes the chat card when it expands the drawer.
  - `showTranscript(at:)` (from a chip) sets `transcriptOpenedFromChat = true`, closes the card, and calls `live.reveal(atRecordingTime:)`.
  - `backToChat()` reopens the card and clears the flag.
- `LiveTranscriptOverlay` renders the slot:
  - **`.collapsed`:** the existing `LiveToggleButton`, plus `ChatQuestionField(placement: .recordingRow)` 12 pt to its right, its trailing edge at the notes column's trailing edge. `RecordingView` passes `notesColumnTrailing` into the overlay, measured where it already measures the notes column.
  - **`.chat`:** `ChatCard(placement: .recordingCard)` in the drawer's frame, with the same `drawerWidth`, the shared `drawerHeight` and `DrawerResizeHandle`, and the bare `LiveToggleButton` passed as `footerLeading`. The footnote sits in the bottom gutter under the card.
  - **`.transcript`:** unchanged, except `DrawerHeader` shows the "Back to chat" pill after the "TRANSCRIPT" label while `transcriptOpenedFromChat` is set.
- `notesBottomInset` treats `.chat` like an expanded drawer.

## Transcript highlight (`TranscriptUI`)

- `TranscriptBubbleList` gains `highlight: Binding<TranscriptHighlight?>`, where `TranscriptHighlight` is `(time: TimeInterval, until: Date)`.
- `FollowController.reveal` already finds the item containing a time. The list resolves the highlight to that item's ID, and `TranscriptItemRow` gets `isHighlighted`.
- A highlighted row fills its bubble with `findHighlightFocused` instead of its usual fill and shows its time, 11 pt mono `inkSecondary`, 8 pt to the bubble's right.
- After 2 s the list fades the fill back over 0.6 s (`.easeOut`; no animation under Reduce Motion) and clears the binding.
- The drawer and the Transcript tab both pass the binding.
- **A reveal holds its place in the live drawer** (`FollowController`, added in phase 10 after hardware check F14). A drawer that opens for a time (a chat chip, or a note's time) asks for the newest item while it lays out, and that scroll can land before or after the reveal's. For `appearanceSettle` (1 s) after a reveal, reaching the bottom does not resume following: the list asks for the revealed item again and stays reading back, with the held items and Return to live. Return to live ends the hold at once. Two limits follow from it, both intended, as they match live_transcript's functional spec ("Clicking a note's time … stops following") and keep a chip's highlight in view:
  - Revealing an item in the last screenful stays reading back at the bottom, instead of resuming following.
  - A reader who scrolls to the bottom within that second is pulled back to the revealed item until the second ends, like the appearance settle's limit (live_transcript `components/transcript_bubble_view.md`, "Appearing"); reaching the bottom later, or Return to live, follows again.

  Find is exempt: while find is open, a landing at the bottom inside that second is left to find (a match in the last screenful stays in view), and the list is not pulled back to the revealed item.

## Meeting page (`MeetingDetailUI`)

- The pinned bottom content becomes a `VStack(spacing: 0)`:
  - A 24 pt `LinearGradient` from clear to `paper`.
  - The field band: `paper`, holding `ChatQuestionField(placement: .meetingPage)` with the content column's horizontal insets and 10 pt bottom padding.
  - The existing `pinnedTransportBar`.

  This goes through the same `safeAreaInset(edge: .bottom)` in both layout paths, so content scrolls behind the band and never under the field.
- While the card is open, the band shows no field. `ChatCard(placement: .meetingCard)` is an `.overlay(alignment: .bottom)` of the page, with the field's width, its bottom 7 pt above the transport bar, its height from `meetingChat.cardHeight` (UserDefaults, default 60% of the page, clamped to 200 pt…full height), and a `DrawerResizeHandle`-style top edge.
- `MeetingDetailViewModel` gains `chat: MeetingChatState` and `showTranscript(at:)`. That method sets `selectedTab = .transcript`, `transcriptRevealTime = t`, the transcript highlight, and calls `seek(to: t)` without playing.
- `load()` also calls `chat.load(meetingID:)`. Selecting another meeting closes the old meeting's card (`isCardOpen = false` in `onDisappear`).

## Menu command (`App`, `AppShellUI`)

- `App/Sources/MeetingChatCommands.swift`: `CommandGroup(after: .sidebar)`, with "Ask About This Meeting" (⌘J) next to the transcript command, enabled when `ChatCommandModel.isAvailable`.
- `AppShellUI/ChatCommandModel.swift`, like `LiveCommandModel`: it knows the visible meeting (recording or detail), and `perform()` opens that meeting's card and sets its `focusRequest`, which the field turns into focus.

## Dependencies

- `MeetingChat`, `DesignSystem`, `TranscriptUI` (`TypingDots`), `Formatting`.
- Used by `RecordingUI`, `MeetingDetailUI` and `AppShellUI`.

## Test Plan

`MeetingChatUITests`:
- `fieldPlaceholders`: no thread, card closed with a thread, and card open give "Ask about this meeting", "Continue chat" and "Ask a follow-up".
- `fieldButtons`: empty → `.sendDisabled`; text → `.send`; answering → `.stop`; unavailable → `.none`.
- `unavailableFieldTexts`: each `ChatAvailability` maps to the UI design's text and action ("Open Settings", "Turn On", none).
- `characterCountAppearsAt1800`.
- `historyItemsNewestFirst`: titles, open-thread checkmark, "5:21 PM" today and "Oct 26" earlier.
- `copyTextStripsMarkdown`: "**A base** it lives in [0:34]" copies as "A base it lives in 0:34".

`TranscriptUITests`:
- `highlightResolvesToContainingItem`, `highlightClearsAfterTwoSeconds`.

`RecordingUITests`:
- `bottomSlotRules`: opening chat collapses the drawer; expanding the drawer closes the chat; `.chat` takes precedence when both are requested in one update.
- `chipOpensDrawerWithBackToChat`: `showTranscript(at:)` reveals the time and sets `transcriptOpenedFromChat`; `backToChat()` reopens the card.

`MeetingDetailUITests`:
- `chipSwitchesToTranscriptAndSeeks`: it sets the transcript tab, the reveal time and the highlight, and seeks without playing.
- `changingMeetingClosesCard`.

`AppShellUITests`:
- `askCommandAvailability`: enabled on a meeting page and on the recording screen, disabled on Home and Settings.

SwiftUI previews cover every state of the field, the card (streaming, complete with chips, stopped, failed, interrupted, unsaved), the History menu, the "Back to chat" header, and dark mode.
