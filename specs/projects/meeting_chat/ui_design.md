---
status: complete
---

# UI Design: Meeting chat

Chat appears in two places: the recording screen and the saved meeting page. Both use the same field and the same chat card. The behaviour behind every element is in the [functional spec](functional_spec.md).

Mockups M1–M6 illustrate this design. They were made on 27 October 2026 by rendering these parts in HTML with the app's design tokens and compositing them onto screenshots of a test build. They are kept outside the repo. Where a mockup and this text differ, this text wins.

All colours, radii and spacing below are existing `DesignSystem` tokens (`Tokens`, `Color+Theme`), named in backticks.

## Shared parts

### The question field

One component everywhere: a 40 pt pill, `cardFill` with a 1 pt `cardStroke` border and a soft shadow (no shadow inside a card), 14 pt text with 16 pt left padding. A 28 pt round button sits 6 pt from its right end.

| State | Placeholder | Round button |
|---|---|---|
| No thread open | "Ask about this meeting" | Send, disabled: `neutralChip` fill, `inkTertiary` arrow |
| A thread exists, card closed | "Continue chat" | Send, disabled until there is text |
| Card open | "Ask a follow-up" | Send, disabled until there is text |
| Text typed | (the text) | Send: `accentFill` (sage) with a white arrow |
| An answer is being written | (empty) | Stop: an `ink` circle with a 9 pt `cardFill` rounded square (white in light mode; it stays visible in dark mode, where `ink` is light) |

- Return sends. Shift-Return adds a line, and the field grows up to five lines, then scrolls. Esc stops an answer that is being written; with no answer running, Esc closes the card.
- Over 1,800 characters, a small gray count appears under the text, at the field's right, such as "1,950 / 2,000". Typing stops at 2,000.
- The footnote, "Answers come from the on-device AI and can be wrong.", is 10.5 pt `inkTertiary`, centered under the field whenever the card is open.

**Unavailable:** the field keeps its shape but has a light gray fill and no shadow. The reason replaces the placeholder in 13.5 pt `inkSecondaryLegible`, and an action, when there is one, is a small bordered button inside the field's right end: `cardFill`, `cardStroke` border, `chipRadius`, 12.5 pt sage medium text.

| Situation | Text in the field | Action button |
|---|---|---|
| No AI model downloaded | "Download the AI model to ask about meetings" | "Open Settings" (Settings → AI Enhancements) |
| Live transcript off, during a recording | "Turn on the live transcript to ask during the meeting" | "Turn On" |
| Saved meeting with no transcript | "This meeting has no transcript to ask about" | none |
| Still transcribing, no draft with text | "Ask once the transcript is ready" | none |
| Another meeting's chat is answering | "Answering in another meeting…" | none |

### The chat card

The transcript drawer's card style: `cardFill`, 0.5 pt `cardStroke` border, `drawerRadius` (16 pt), and on the saved meeting page a soft shadow. Its top edge is draggable.

- **Header**, 43.5 pt like the drawer's, with a `hairline` under it. At the left, the History button: a clock-with-arrow icon and a small chevron, `inkSecondary`, no text. At the right, "New chat" (a square with a pencil) and a minus that closes the card, drawn like the drawer's icon buttons and as tall as History (26 pt).
- **History menu:** a standard macOS menu from the History button, which shows its pressed state while the menu is open. It lists the meeting's threads by name (the first question, cut to about 60 characters), most recently used first, with the time of its last question or answer as a gray line under the name ("5:21 PM" for today, "Oct 26" for earlier days); SwiftUI menus cannot right-align text. The open thread has a checkmark. After a separator come "New Chat" (⌘N while the card has focus) and "Delete This Chat…". Deleting asks first, in a standard alert: "Delete this chat?", "This can't be undone.", with Delete and Cancel buttons.
- **New chat:** closes the card and puts the cursor in the field, which reads "Ask about this meeting". The new thread exists once its first question is sent.
- **Hover:** every chat button answers the pointer in one way: an enabled button takes the `neutralChip` wash in its own shape while the pointer is over it or it is pressed, as History and Copy do. That covers New chat and Close (26 pt squares, as high as History), Copy, the jump-to-newest button, and the bordered Retry, Open Settings and Turn On. Send with text and Stop keep their fill and lighten to 85% instead, so Send stays green. A disabled button, such as Send with no text, does not respond. The transcript drawer's own header buttons (`TranscriptUI`, live-transcript code) still have no hover state; B9's drawer header is where to fix them.
- **Body:** a scrolling list with 24 pt side padding, anchored to the bottom, so a short thread sits just above the field.
  - **A question** is a right-aligned bubble, at most 72% of the width: `cardFill` with a 1 pt `cardStroke` border, `bubbleRadius` (14 pt), 7 × 12 pt padding, 14 pt `ink` text. It is deliberately neither transcript colour: "Others" bubbles are `neutralChip` and "You" bubbles are `softSageFill`.
  - **An answer** starts 16 pt below its question: full-width 14 pt `ink` text, line height 1.45, 8 pt between paragraphs, rendered from the model's Markdown (bold, bullet and numbered lists, short headings). Bullets are 4 pt `inkTertiary` dots with an 18 pt hanging indent.
  - **Times** in an answer are chips: 11.5 pt JetBrains Mono, sage text on `accentWashSoft`, 5 pt radius, 1 × 5 pt padding, with no parentheses. The pointer becomes a hand over them. A click, or Space or Return on a chip that has the keyboard focus, goes to the cited line.
  - **Chip preview:** when the pointer rests on a chip for about the system tooltip delay (1 s), the cited transcript line shows next to it, 6 pt below the chip, or 6 pt above it when the list has no room below: a `cardFill` bubble with a 0.5 pt `cardStroke` border, `chipRadius` and a soft shadow, at most 320 pt wide and kept 12 pt inside the list's edges. Its first line is the speaker and the line's start time, "Alex · 10:32", in 11.5 pt medium `inkSecondaryLegible` (the time alone when the line names no speaker); under it, up to three lines of the line's text in 13 pt `ink`. It is the line a click goes to, in the transcript a click shows. It goes away when the pointer leaves the chip, or with a click, and does not take clicks itself. VoiceOver does not see it; the chip's label names its target.
  - **Under a finished answer**, 8 pt below, a left-aligned row: a 14 pt copy icon in `inkTertiary`, then 11.5 pt `inkSecondary` text: "Based on the transcript through 0:46" during a recording, "Based on the draft transcript" for a draft, nothing otherwise. Copying shows "Copied" briefly in place of the icon.
  - **Turns** are 26 pt apart.
  - **Before the first word** (Backlog B10, 30 October 2026), the answer's place shows what it waits for:
    - **The model loading:** "Loading the AI model… 12 s", 13 pt `inkSecondaryLegible` with monospaced digits, over a small linear progress bar, at most 240 pt wide, 8 pt below it. The bar fills against the model's last load time on this Mac and stops at 90% until the load ends. Past that time the text reads "Loading the AI model… 52 s, longer than last time". With no earlier load, the bar is indeterminate. No spinner.
    - **Other waits:** a status line in `inkSecondaryLegible` with a small spinner: "Waiting for the summary to finish…" or "Answers when the recording stops" (no Mac waits for Stop by default, per Backlog decision B4; the wait-for-Stop mode remains, reachable only from tests and the chat load driver).
    - **The model reading the meeting:** the three typing dots alone, at once after Send or after the load ends, until the first word. They replace the "Thinking…" line. No skeleton is drawn for any wait.
  - **While an answer streams**, three 4 pt `inkTertiary` dots sit on their own line under its text. They end with the answer, however it ends. An answer that ended with no words shows "The AI gave no answer" in its footer row, with Retry. The list follows the newest text unless the user scrolls up, in which case a round down-arrow button appears at the bottom center; it jumps back to the newest text.
  - **A stopped answer** keeps its text, and its row reads "Stopped".
  - **A failed answer** shows the error in a short sentence, in `signalRedText`, with a "Retry" button.

### Settings → AI Enhancements

"Keep the AI Model Ready" is a toggle under "AI Language Model", off by default and disabled with no model downloaded, with a footnote in the section's metadata style: "Loads the AI model at launch and keeps it loaded, so chat answers sooner. Uses about 7 GB of memory while Biscotti is open." The size is the selected model's file size, in whole GB. On Macs with less than 24 GB the footnote adds "During recordings, it still closes after each answer to free memory."

## Recording screen

- **Drawer closed** (M1): the bottom row holds the round level-meter button and, 12 pt to its right, the field, vertically centered on the button and reaching the right edge of the notes column.
- **Chat open** (M2): sending a question opens the chat card in the drawer's place, at the same position, width and height. The drawer and the chat share one height setting, dragged from either card's top edge. The card's footer holds the level meter and its chevron at the left, as in the drawer's footer (it opens the transcript), then the field. The footnote sits under the card, in the window's bottom margin.
- **Switching:** the level-meter control opens the transcript drawer and closes the chat. The drawer's footer is unchanged, with the "English" language menu in place of the field. Closing the drawer brings back the bottom row, where the field reads "Continue chat"; clicking it reopens the chat card on the same thread.
- **A time chip** (M3): opens the drawer at that moment. The cited bubble takes the find highlight (`findHighlightFocused`, sage at 35%) for 2 seconds, with its time in 11 pt JetBrains Mono `inkSecondary` to the right of the bubble. While the drawer was opened from the chat, its header shows a "Back to chat" pill right after the "TRANSCRIPT" label: a left chevron and the text, 12.5 pt sage medium on `accentWashSoft`. It reopens the chat at the same scroll position.
- The View menu gets "Ask About This Meeting" (⌘J), which opens the chat card and focuses the field, next to the existing "Show Transcript" (⌘T). The architecture step confirms ⌘J is free.

## Saved meeting page

- **The field** (M4): as wide as the meeting's content column (the left edge of the title to the right edge of "Copy", which is also the playback row's width), 10 pt above the playback bar, on every tab. It sits on a band of `paper`, and the page's content fades into that band over 24 pt above it, so content is never cut off mid-line.
- **The card** (M5): rises from the field, as wide as it, with the field inside the card's footer and the footnote under the field. Its bottom edge sits 7 pt above the playback bar. At first it covers the lower 60% of the page; its top edge is draggable between 200 pt and the full page height, and the height is remembered across meetings.
- **A time chip:** switches to the Transcript tab, scrolls the cited segment into the visible area above the card, gives it the find highlight for 2 seconds, and moves the playback position there without playing. The card stays open.
- **Changing meetings:** selecting another meeting closes the card. Each meeting remembers its last open thread, so its field reads "Continue chat".
- **After a relaunch:** each meeting's chat starts as after a change of meeting: the card closed and the field reading "Continue chat" on the thread that was open at quit, with any half-typed question still in it. A meeting with no open thread reads "Ask about this meeting". Sending a question clears the kept text.
- **After Stop:** the meeting page opens with the card closed and the field reading "Continue chat"; one click reopens the thread. While an answer is being written, or waits for Stop, the card stays open.
- **Unavailable** (M6): the field shows the reason and, for a missing model, "Open Settings".

## Accessibility and appearance

- **VoiceOver labels:**
  - Field: "Ask about this meeting". Send: "Send question". Stop: "Stop answer".
  - History button: "Chat history, [thread name]". "New chat". Close: "Close chat".
  - Time chips: "Go to 0:42 in the transcript", read as a link after the paragraph that holds them, in reading order. A range chip reads as written: "Go to 12:34–13:10 in the transcript". Copy: "Copy answer".
- **Announcements:** an answer is announced once it finishes, not word by word. Status lines are announced when they change. The model load is read and announced as "Loading the AI model", without its seconds, once when it starts and once if it runs past the last load time ("…, longer than last time"). The dots before the first word read "Thinking" and are announced once; the dots under streaming text read "Writing".
- **Keyboard:** everything works from the keyboard. With macOS keyboard navigation on, Tab goes History, New chat, Close chat, then, answer by answer, the answer's chips in reading order and its Copy, then the field and Send. Space (or Return) on a chip does what a click does.
- **Dark mode:** every colour above is a dynamic token with a dark value; the card, bubbles and chips follow the transcript drawer's dark look.
- **Reduce Motion:** the card appears without sliding.
