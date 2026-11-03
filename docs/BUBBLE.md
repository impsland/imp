# The full bubble (chat)

The full bubble is the expanded chat window over the Imp. It is a frosted card with a transparent margin for its shadow and the corner buttons.

## Layout, top to bottom

1. Header (24 pt). The chat title as a menu of saved chats and talks, in primary text with a chevron. Then Recap, New chat and Delete, each a 24 pt target with a tooltip and a VoiceOver label. Recap, New chat and Delete ask first. A divider separates the header from the transcript.
2. Transcript. Fills all the height the text box leaves, with a minimum of 80 pt, and scrolls. Newest turn at the bottom. Dates and labels are 11 pt secondary, replies 13 pt. Replies and requests have the same 14 pt padding on the left and the right.
3. Input. A rounded well (`Radius.medium`) with the text field, the mic (outside a chat) and the send button. The field grows line by line up to the maximum and then scrolls inside. The send button stays on the bottom line. Return sends, Shift+Return adds a line, Escape closes.

The close button, chat button and copy or reply buttons sit on the card's corners. They stay visible in the chat.

## Sizes

- Default 440 x 520 pt (the card, without the margin). Minimum 320 x 320 pt.
- Maximum: the visible screen less 56 pt wide and 72 pt tall, so the card and its corner buttons stay on screen.
- The user drags any edge or corner (a grip marks the bottom corner). The opposite sides stay put. The panel is kept on the visible screen.
- The size is saved when the drag ends and restored on the next launch, clamped for the screen it opens on (`BubbleSizing.clamped` in ImpKit).

## Settings that affect it

- Settings, General, Talking, Answers, "Text box lines" (`ImpPreferences.inputMaxLines`, default 6, from 2 to 12).
- "Chat size" shows the saved size, and "Reset size" returns to the default (`ImpPreferences.chatBubbleSize`).
- Hide after, Autoplay media and Audio look change what replies show, not the layout.

## Notes

- Why a reply once had more room on the right: the transcript and the reading scroll added a 10 pt right padding as a scroll bar gutter. It is gone. The scroll bar takes its own room only while the text overflows.
- Reduce Motion: the chat adds no motion of its own.
