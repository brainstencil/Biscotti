# Granola's meeting chat, from a screen recording

Source: a 2.5-minute screen recording of Granola's macOS app, made by the user on 27 October 2026, with no audio. It shows chat on one saved meeting, then the full-window chat view. These notes describe what the video shows; they are a competitor baseline, not requirements.

## The chat field

- The meeting page ends with one bar: a recording control on the left ("Resume" with a level meter), then a field reading "Ask anything", with one suggested prompt inside it ("Write follow up email"). After a chat exists, the field reads "Continue chat".
- Clicking the field raises a row of preset prompts that Granola calls recipes: "Write follow up email", "List my todos", "Make notes longer", "Write tldr" and "All recipes". The field's right side holds a model menu ("Auto"; other models need a paid plan), an attachment button (it opens a file picker), and a microphone button for dictation that turns into a send arrow once text is typed.
- Below the field, a footnote reads "Granola uses AI and can make mistakes."

## Asking and answering

- Sending a question opens a panel above the field. The panel has a history menu on the left, and "open in new window" and "expand" buttons on the right.
- The question shows as a small right-aligned bubble. The answer starts with "Thinking…", then streams in as full-width text with bold lead-ins, bullets and numbered lists. A collapsible "Thought for 1s" line can precede it.
- While an answer streams, the send button becomes Stop. A down-arrow button jumps to the newest text when the user has scrolled up.
- Answers quote the meeting and stay grounded in it: asked "Who is John Carreyu?", it answered "You likely mean John Carreyrou" and described him only from what the clip said.
- After an answer: a "Say more" button, then copy, a screenshot-style button, and thumbs up and down. The recipes row stays under the latest answer.
- Running a recipe shows it as the user's message, with the recipe's icon and name and a regenerate button, then streams the result (for "Write tldr", a one-line summary and two bullets).
- Dictation replaces the field with a live waveform, a timer, and cancel (Esc) and confirm buttons.

## History and the full-window view

- "Expand" opens chat in the main window, beside the app's sidebar, which has a "Chat" section of its own. The view has a "History" menu and a "New chat" button. The first question carries a reference chip naming the meeting and its date ("Audio clip on Fa… Sunday 9:17 pm"), which shows what the chat is about.
- Collapsing returns to the meeting, where the bar reads "Continue chat". A later "give me a detailed summary of the meeting" in a fresh chat streamed a long, sectioned answer that also described a gap in the recording ("you said you were taking out your AirPods").

## Frames

Eight contact sheets of 30 frames are kept outside the repo, in the user's demo folder (`meeting-chat/granola-frames`).
