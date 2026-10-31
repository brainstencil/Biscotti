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

Internal views: `ChatCardHeader` (History button with `Menu`, New chat, close), `ChatMessageList` (a `ScrollView` + `LazyVStack` anchored to the bottom with `.defaultScrollAnchor(.bottom)`, following new text unless the user scrolled up, plus the round down-arrow button and the chip preview overlay), `ChatQuestionBubble`, `ChatAnswerView`, `ChatAnswerFooter`, `ChatStatusLine`, `ChatFootnote`, `ChatChipTargets`.

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
- **Time chips:** before rendering, runs carrying `ChatTimeAttribute` get JetBrains Mono 11.5 (`Font.biscottiMono(11.5)`), sage foreground and a custom `ChatChipAttribute: TextAttribute` whose ID is the segment's index. The text holds no links (model output links nowhere). The block's `Text` uses `.textRenderer(ChatChipRenderer())`, a `TextRenderer` (macOS 15) that, for each run with `ChatChipAttribute`, fills a rounded rectangle (radius 5, `accentWashSoft`, 5 pt horizontal and 1 pt vertical outset) behind the run's typographic bounds, then draws the text.
- **Chip targets** (added 30 October 2026, after hands-on checks U3 and F6/A12 found no hand pointer and no keyboard access). SwiftUI text links take no keyboard focus and set no pointer, so the chips act through clear views laid over them: `.overlayPreferenceValue(Text.LayoutKey.self)` reads the block's own text layout, and `ChatChipRenderer.chipRects(in: Text.Layout)` gives each chip's rectangles, one per line it is on, with the same run grouping the renderer draws. `ChatChipTargets` puts a `Button` (plain style, `.pointerStyle(.link)`, a `.focusEffect` content shape in the chip's rounded rectangle) over each chip's first rectangle and a click area over the rest of a wrapped chip. The button calls `onTime` on a click and on Space; `.onKeyPress(.return)` does the same. It is the chip's only accessibility element: "Go to \(label) in the transcript" (`ChatAnswerText.Chip.accessibilityLabel`) with the link trait, after the paragraph in reading order. Every chip is a target, so a time cited twice is two Tab stops. The answer's earlier per-text accessibility actions are gone with the links.
- **Chip preview.** While the pointer rests on a target, it waits `ChatChipPreviewPresentation.restDelay` (1 s, about the system tooltip delay) and asks `MeetingChatService.citedLine(at:meetingID:)` for the line, looked up during the wait. The target publishes the line and its bounds' anchor through `ChatChipPreviewKey`; `ChatMessageList` draws the bubble in an overlay over the scroll view (`chatChipPreview()`), so later rows do not cover it and the scroll view does not clip it. `ChatChipPreviewPresentation` gives its heading ("Alex · 10:32", or the time alone), its text (with a live line's tail) and its place: below the chip, above it when there is no room below, inside the list's edges. Leaving the chip, or clicking it, removes it. It is hidden from accessibility and takes no clicks.
- Streaming dots (`TypingDots`) follow the last block while the state is `.streaming`.

**Before the first word** (Backlog B10, 30 October 2026). `ChatAnswerPresentation.slot(for:)` gives what an answer shows, as a `ChatAnswerSlot`:
- `.loadingModel` (status `.loadingModel`): `ChatModelLoadLine`, the text "Loading the AI model… 12 s" (13 pt, `inkSecondaryLegible`, monospaced digits) over a small linear `ProgressView`, at most 240 pt wide. `ChatModelLoadPresentation.make(elapsed:estimate:)` gives its text, fraction and VoiceOver text from `MeetingChatService.modelLoad`, redrawn every 0.25 s by a `TimelineView`. With an estimate (the model's last load on this Mac), the bar fills by `elapsed / estimate`, capped at 0.9 (`maximumFraction`), so it never shows a load as done before it is; past the estimate the text reads "Loading the AI model… 52 s, longer than last time". With no estimate, the bar is indeterminate and the text still counts the seconds. VoiceOver reads "Loading the AI model" (and ", longer than last time" once past the estimate), with no seconds, and hears it once at the start and once when it runs late.
- `.status(text)` (waiting for the summary, or for Stop): `ChatStatusLine`, the spinner and the text, as before.
- `.firstWord` (status `.thinking`, no text yet): the typing dots alone, at once after Send or after the load ends, labelled "Thinking" for VoiceOver and announced once. They replace the "Thinking…" spinner line.
- `.text(isStreaming:)`: the blocks, with the dots ("Writing") under them while the answer streams. Every ending (complete, stopped, interrupted, failed) is `.text(isStreaming: false)`, so the dots always end with the answer; its footer says how it ended.
- A complete answer with no text (a stream that ended with no words) would leave a blank slot: its footer reads "The AI gave no answer" with Retry, and that is what VoiceOver announces.

No skeleton is drawn for either wait. The Interface Lineage review (`demo/meeting-chat/interface-lineage-audit.md` §7, §8, §11) found it fits neither: the answer has no known layout, it looks the same at 3 s and at 30 s, and NN/g limits skeletons to waits under 10 s.

**Hover.** One state for every chat button (`ChatHover`): the `neutralChip` wash in the button's shape while hovered or pressed, if enabled. Icon buttons use `ChatHoverButtonStyle` (`HoverHighlight`): History, Copy, and `ChatHeaderIconButton` (New chat, close; 26 × 26 pt). The bordered buttons (`ChatInlineButtonStyle`: Retry, Open Settings, Turn On) and the jump-to-newest circle (`ChatCircleButtonStyle`) draw the wash over their `cardFill`. `ChatRoundButton` keeps Send's and Stop's fill and draws it at `ChatHover.filledOpacity` (85%) under the pointer; disabled Send does not change. `TranscriptUI`'s drawer header is live-transcript code and keeps `.plain` buttons; B9 fixes it there.

**Footer row.** A 14 pt copy icon button (`doc.on.doc`, `inkTertiary`, `HoverHighlight`). It copies the answer's plain text (Markdown markers removed, chips as their time) and shows "Copied" for 1.5 s. Then the footer text, 11.5 pt `inkSecondary`. "Stopped" shows for a stopped answer; a failed answer shows its error in `signalRedText` and a "Retry" button; `isUnsaved` adds "Couldn't save this answer".

**Status line.** `ProgressView().controlSize(.small)` and the status text: "Waiting for the summary to finish…" or "Answers when the recording stops". The model load has its bar and the first word its dots (above).

**Load on focus.** The text field's `.onChange(of: focus.wrappedValue, initial: true)` calls `MeetingChatService.questionFieldDidTakeFocus(meetingID:)` when the field takes the cursor, so the model loads while the question is typed.

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
- **A reveal checks where it landed** (`RevealLandingCheck`, added in phase 10 after hardware check F14 failed far from the live end). The transcript list makes its rows lazily and estimates the heights of rows it has not made, so a scroll to a far item can land short of it or past it. 200 ms after the list performs a scroll to a revealed item, it checks the item's row against what the reader sees; out of view, it asks for the item again, at most three times. What the reader sees is the scroll view less its content insets: on the meeting page the list runs under the pinned band and, with the card open, under the card (`safeAreaInset` and `safeAreaPadding`), so a row behind them counts as below. A check made while the scroll to the item is still waiting uses no attempt. An explicit scroll (a find match) replaces the reveal and ends the check, and so does Return to live. Each check logs where the reveal landed against its time, with the view's height and insets. In both the live drawer and the Transcript tab. Rows and the list report their frames in the window, and rows are read against the scroll view's top, the list's top less the top inset: a macOS `List` is not a SwiftUI `ScrollView`, so a row's `.scrollView` frame does not measure from the list (it read every row in the drawer as below), and the List's own frame excludes the content insets (measured on macOS 26.6.2 on the meeting page: 52 pt down the window, 206 pt high in a 1290 pt view with insets of 52 and 1032 pt). A List as high as its scroll view, as other macOS versions may lay it out, is read as the scroll container: rows against its top.

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
- `slotsBeforeTheFirstWord`: `.loadingModel` gives the bar, the summary and Stop waits their status lines, `.thinking` the dots.
- `dotsEndWithTheAnswer`: words while streaming show the dots under them; every ending, with or without text, shows none.
- `noAnswerFooter`: a complete answer with no text says "The AI gave no answer", with Retry, and announces it.
- `loadWithoutEstimate`, `loadFillsAgainstEstimate`, `loadLongerThanLastTime`: no estimate gives an indeterminate bar with the seconds; the bar fills against the estimate and stays at 0.9 past it; past the estimate the text says "longer than last time", and the VoiceOver text changes once, without seconds.
- `chipLabelsReadAsWritten`: every chip in reading order, a repeated time twice, each labelled "Go to … in the transcript" by its own text; `chipSegments`: the text holds no links.
- `ChatChipTargetTests`: a real text layout (rendered with `ImageRenderer`) gives each chip one rectangle, in reading order on one line and on a later line when the text wraps; the preview's heading and text for a saved, a live and an unnamed line; its placement below, above, and on the roomier side, kept inside the list.

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
