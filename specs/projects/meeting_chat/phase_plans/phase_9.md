---
status: complete
---

# Phase 9: Chat placement

## Overview

Places the chat components that phase 8 built ([chat_ui](../components/chat_ui.md), [ui_design](../ui_design.md)): the recording screen's bottom slot with the row field, the chat card in the drawer's place and "Back to chat"; the transcript highlight that a time chip leaves on the cited bubble; the meeting page's field band and card; and the View menu's "Ask About This Meeting" (⌘J). It also carries three service fixes from phase 4's review and a cross-reference comment in `TranscriptUI`.

The manager's placement rules apply (`.specs_skill_state/phase9-brief.md`): every change between the field outside the card and the card's field, and ⌘J, goes through `MeetingChatState.focusRequest`, with the card opened before `onAction(.openCard)` returns; "Back to chat" reopens the chat at the same scroll position, so the card stays in the view hierarchy, hidden, while the drawer it opened shows; and no text promises that Turn On catches up from the start of the recording (B1).

## Steps

1. **Service fixes (MeetingChat).**
   - `MeetingChatService+Answer.swift`: the lease body returns `LeaseAnswer` (`.read(sawDone: Bool)` or `.promptFailed(ChatPromptError)`). `answer(_:record:in:)` catches `ChatPromptError` from `ChatPromptBuilder.build` and returns it, so the lease ends without an error and the broker keeps the connection; `answerOutcome` maps `.promptFailed` to `.failed`.
   - `MeetingChatService.swift`:
     - `public func transcriptWasSaved(meetingID: UUID)`: sets `transcriptFlags[meetingID] = true`, synchronously.
     - `pendingFinalPasses: Set<UUID>` (observed), `public func finalPassWillStart(meetingID:)` and `public func finalPassDidEnd(meetingID:)`. Availability step 4 reads `isTranscribing(id) || pendingFinalPasses.contains(id)`. `meetingWasDeleted` removes the meeting from the set.
   - `AppCore+Chat.swift`: the `onTranscriptSaved` hook calls `chat.transcriptWasSaved(meetingID:)`.
   - `AppCore.swift`: `stopRecording()` calls `chat.finalPassWillStart(meetingID:)` right after `recording.stop()` returns; `finalPassAfterStop` calls `chat.finalPassDidEnd(meetingID:)` after `transcription.transcribe` and drops the explicit `await chat.refreshAvailability()`.

2. **TranscriptUI.**
   - `TranscriptHighlight.swift`: `public struct TranscriptHighlight: Equatable, Sendable { time; until: Date }`, `init(time:now:)` with `until = now + 2 s`, `duration = 2`, `fadeDuration = 0.6`, `remaining(at:) -> TimeInterval`.
   - `TranscriptBubbleList`: a `highlight: Binding<TranscriptHighlight?> = .constant(nil)` parameter on both inits. `static func highlightedItemID(_:in:)` resolves it with `FollowController.revealTarget(for:in:)` over the shown items. A `.task(id: highlight)` waits until `until`, then clears the binding inside `withAnimation(.easeOut(duration: 0.6))`, or without animation under Reduce Motion.
   - `TranscriptItemRow`: `var isHighlighted = false`, part of `==`. A highlighted bubble fills with `findHighlightFocused` and shows its start time (11 pt mono, `inkSecondary`) 8 pt outside the bubble: to its right for a leading bubble, to its left for a trailing one. The play button that shares that side stays hidden while highlighted.
   - `TranscriptItemBuilder`: the comment "Mirrored in `MeetingChat/ChatEvidence.swift` (`mergedGaps`, `GapStretch`); change both." next to `minimumGapMarker` and `GapStretch`.

3. **DesignSystem.** `TopEdgeResizeHandle` (public), moved out of `RecordingUI`'s private `DrawerResizeHandle` and made generic: `init(label:height:range:step:dragHeight:onSave:onReset:)`. The drawer, the recording chat card and the meeting card use it.

4. **Package.** `RecordingUI` and `MeetingDetailUI` gain `MeetingChat` and `MeetingChatUI`; `AppShellUI` gains `MeetingChat`. Their test targets gain `MeetingChat`.

5. **Recording screen (RecordingUI).**
   - `RecordingViewModel` stores `transcriptOpenedFromChat` and `transcriptHighlight`.
   - New `RecordingViewModel+Chat.swift`: `public enum RecordingBottomSlot { collapsed, chat, transcript }`; `chat: MeetingChatState?` (the recording meeting's); `chatService`; `bottomSlot` from `static func bottomSlot(isCardOpen:isDrawerExpanded:showsLive:)`, where the card wins; `openChat()` (opens the card, collapses the drawer, clears the flag); `showTranscript(at:)` (sets the flag, closes the card, sets the highlight, `live.reveal(atRecordingTime:)`); `backToChat()`; `drawerDidCollapse()` (clears the flag); `chatAction(_:)` (`.openSettings` → `core.showSettings()`, `.turnOnLiveTranscript` → `core.chat.turnOnLiveTranscript()`, `.openCard` → `openChat()`).
   - `RecordingViewModel+Live.swift`: `toggleDrawer()` closes the card when it expands the drawer and clears the flag; `collapseDrawer()` clears the flag; `revealNoteInTranscript` closes the card and clears the flag.
   - `LiveToggleButton`: `var isInCard = false`; bare (no circle, no shadow) when the drawer is open or it sits in the card.
   - `LiveTranscriptOverlay` renders the slot. `.collapsed`: the toggle (when live transcription runs) and, 12 pt to its right, `ChatQuestionField(.recordingRow)` with the width from `static func rowFieldWidth(notesColumnTrailing:showsToggle:)`, its centre on the toggle's. `.transcript`: the drawer and the toggle, as now. `.chat`: `ChatCard(.recordingCard)` in the drawer's frame and height, with the resize handle and the bare toggle as `footerLeading`. While the drawer shows after a time in the chat, the card stays below it, hidden, disabled and out of hit testing and VoiceOver, so its list keeps its scroll position. `notesBottomInset(slot:drawerHeight:)` treats `.chat` like the open drawer.
   - `LiveTranscriptDrawer`: the header shows a "Back to chat" pill (left chevron and text, 12.5 pt sage medium on `accentWashSoft`, capsule) after the "TRANSCRIPT" label while `transcriptOpenedFromChat`; the list gets the highlight binding.
   - `RecordingView`: measures the notes column's trailing edge where it measures the column's top, and passes it to the overlay in the overlay's coordinates; shows the overlay while the recording has a chat or live transcription runs; owns the chat field's `@FocusState`; moves the notes for `.chat` as for the open drawer; on the drawer collapsing, calls `drawerDidCollapse()`; a hidden slot clears a drag height.
   - Previews: the recording screen with the chat row, and the drawer opened from the chat with "Back to chat".

6. **Meeting page (MeetingDetailUI).**
   - `MeetingDetailViewModel`: `public let chat: MeetingChatState`, `chatService`, stored `transcriptHighlight`. `showTranscript(at:)` sets the Transcript tab, `transcriptRevealTime`, the highlight, and `seek(to:)` without playing. `load()` also calls `core.chat.load(meetingID:)`. `pageDidDisappear()` closes the card. `chatAction(_:)` as on the recording screen, with `.openCard` opening the card.
   - `MeetingChatCardLayout` (internal): `minimumHeight = 200`, `defaultFraction = 0.6`, `gapAboveTransport = 7`, `maximumHeight(pageHeight:transportHeight:)`, `height(stored:pageHeight:transportHeight:)`.
   - `MeetingDetailView`: both layout paths take one `pinnedBottom` through `safeAreaInset(edge: .bottom, spacing: 0)`: a 24 pt gradient from clear `paper` to `paper` (not hit-testable), the field band (`paper`, `ChatQuestionField(.meetingPage)` with the content column's insets and 10 pt below it), then `pinnedTransportBar`. While the card is open, the band's field stays in place hidden and disabled, so nothing moves. `ChatCard(.meetingCard)` is an `.overlay(alignment: .bottom)` of the page, the field's width, 7 pt above the transport bar, its height from `@AppStorage("meetingChat.cardHeight")` through `MeetingChatCardLayout`, with a `TopEdgeResizeHandle`. `contentFill` subtracts the whole pinned bottom. `onDisappear` calls `pageDidDisappear()`. The transcript list gets the highlight binding.

7. **⌘J (AppShellUI, App).**
   - `AppShellUI/ChatCommandModel.swift`: `core`, `showMainWindow`, `visibleMeetingID` (the recording on the recording screen; the one selected meeting on the Meetings screen), `isAvailable`, and `perform()`: on the recording screen it collapses the drawer; it opens the meeting's card and sets `focusRequest`.
   - `LiveCommandModel.toggle()`: expanding the drawer closes the recording meeting's chat card.
   - `App/Sources/MeetingChatCommands.swift`: `CommandGroup(after: .sidebar)` with "Ask About This Meeting" (⌘J), disabled unless `isAvailable`. `BiscottiApp` declares it after `LiveTranscriptCommands` and wires the model in `buildCore()`.

## Tests

`MeetingChatTests`:
- `tooLongFails` also expects `closeCount == 0`.
- `transcriptWasSavedIsImmediate`: a meeting with no transcript reads `.noTranscript`, then `.available` right after `transcriptWasSaved`, with no await.
- `pendingFinalPassReadsTranscribing`: `.noTranscript` → `finalPassWillStart` → `.transcribing` → `finalPassDidEnd` → `.noTranscript`.

`AppCoreChatTests`:
- `savedTranscriptRefreshesChat`: chat reads `.available` inside the `onTranscriptSaved` hook, the moment the job is `.completed`.
- `stopWithLiveOffReadsTranscribing`: right after `stopRecording()` returns, with the live transcript off, chat reads `.transcribing`; after the pass it no longer does.

`TranscriptUITests`:
- `highlightResolvesToContainingItem`: the bubble holding the time; between bubbles, the one before.
- `highlightClearsAfterTwoSeconds`: `until` is 2 s after now; `remaining` counts down to 0 and stays there.
- Row equality includes `isHighlighted`.

`RecordingUITests`:
- `bottomSlotRules`: opening chat collapses the drawer; expanding the drawer closes the chat; `.chat` wins when both are set; no live transcript means no `.transcript`.
- `chipOpensDrawerWithBackToChat`: `showTranscript(at:)` reveals the time, sets the highlight and `transcriptOpenedFromChat`, and closes the card; `backToChat()` reopens the card and clears the flag; the drawer collapsing clears it too.
- `noteRevealClosesChat`, `chatActions` (Open Settings routes to Settings; Turn On turns the live transcript on; openCard opens the card).
- `rowFieldReachesNotesColumn`: the field's width with and without the toggle, and its minimum.
- `notesBottomInset` per slot.

`MeetingDetailUITests`:
- `chipSwitchesToTranscriptAndSeeks`: the Transcript tab, the reveal time and the highlight are set, and the player seeks without playing.
- `changingMeetingClosesCard`.
- `loadLoadsChatThreads`.
- `cardHeightClamps`: default 60%, stored height clamped to 200 pt and to the page above the transport bar.

`AppShellUITests`:
- `askCommandAvailability`: enabled on a meeting page and on the recording screen, disabled on Home and Settings, and with several meetings selected.
- `askCommandOpensCardAndFocuses`: `perform()` opens the card, sets `focusRequest`, and collapses the drawer on the recording screen.
- `liveCommandClosesChat`: ⌘T expanding the drawer closes the chat card.
