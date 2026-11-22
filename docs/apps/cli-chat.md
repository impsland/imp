# Using the terminal chat

`imp` with no arguments opens the chat, the same as `imp chat`. It talks with the Imp you pick with
`--imp NAME`. Without a name, a terminal opens the only Imp there is, lets you choose when there are
several (arrow keys and Enter, Esc to quit), and when there are none, asks where the model runs, for its
address, key and model, and a name, then opens the chat with the new Imp. Where there is no terminal, a
missing name is an error. This page is about using it. The commands are in
[Commands in the chat](/apps/cli-commands), and Imps that work for other Imps are in
[Sub-agents](/apps/cli-agents).

```text
› Ask zed what he thinks of basil.
⇢ zed: What do you think of basil?
  ⇠ Arrr, basil's a fine herb, makes a tomato taste shipshape.
● Zed likes it: he says it makes tomatoes better.

 › Write a message, / for commands, @ for files
● Pip · openai/gpt-6-luna · ~/projects/my-app                      Ready · ? help
```

## What you see

- `›` is what you wrote and `●` is the Imp.
- `⏺` is a tool the Imp used, with its arguments, and `⎿` is the first line of the result (or `running…`). Click a tool line to open that
  call in full: all its arguments, its whole result, and a diff for file edits. Ctrl+O opens the latest one.
- `⇢` is a message to another Imp and `⇠` is its answer.
- Dim lines are notes from commands and your devices. They are never sent to the model.
- The bottom line shows the Imp, its model and its folder, and what it is doing: `Thinking 3s`,
  `Using the tool read_file`, `Retrying 2 of 3`, `On iPhone`. On a narrow terminal the folder is shortened, then
  left out.
- An empty chat shows the Imp, how to start, and what the folder adds (for example `AGENTS.md · 3 skills`).

## Writing a message

- **Enter** sends. **Alt+Enter**, **Shift+Enter** or **Ctrl+J** adds a line. Pasting several lines works.
- **Left**, **Right**, **Home** and **End** (or Ctrl+A and Ctrl+E) move in the message. Alt or Ctrl with
  Left or Right moves by word.
- **Backspace** and **Delete** erase at the cursor. **Ctrl+W** (or Alt+Backspace) erases the word before it.
  **Ctrl+U** erases everything.
- **`@` adds a file.** Type `@` and what follows, such as `@main`, and the folder's files that match are
  listed. Tab or Enter puts the path in the message. A folder opens to what is in it. When you send, each
  file named with `@` goes with the message for the Imp to read: text up to 100 KB each and 256 KB in all. A
  folder goes as the list of what is in it. Paths with spaces are written `@"my notes.md"`. A word such as
  `@zed` that is not a path is left alone. A picture, a sound or a video (`@photo.jpg`, `@voice.wav`,
  `@clip.mp4`) goes to the model as itself, for models that can see or hear: 25 MB each and 4 in one message.

## Commands and the `/` list

Type `/` to see the commands. The list shows under the message. Keep typing to narrow it: `/ex` already
offers `/quit`, and aliases such as `/exit` work too.

- **Up** and **Down** choose a command in the list.
- **Tab** or **Right** puts the command in the message.
- **Enter** runs it. A command that needs more, such as `/send DEVICE`, is completed first, so you can type
  what it needs.
- **Esc** closes the list. Type a space after a command and a line shows how to use it.

Custom commands from `.agents/commands/` are in the same list, after the built-in ones. They are described in
[Custom commands](/apps/cli-commands#custom-commands).

## Sending again

- **Up** on the first line of your message brings back the message you sent before. Each Up goes one message
  further back and stops at the oldest. Within a message of several lines, Up first moves to the line above.
- **Down** on the last line goes forward again. After the newest message it returns what you were writing, so
  nothing typed is lost.
- **Ctrl+P** and **Ctrl+N** do the same.

## Reading and copying

- **PageUp**, **PageDown**, **Up** and **Down** (when no list is open) and the mouse wheel scroll the chat.
  **Shift+Up** and **Shift+Down** scroll one line at a time while you are typing.
- While you read further up, new lines arrive below without moving what you are reading. The status line says
  `End ↓ latest`. **End** with nothing typed, or Ctrl+End, jumps to the newest line.
- **Drag** over the conversation to choose text. It is copied when you let go, and the status line says
  `Copied`. Two clicks copy a word and three copy a paragraph. Holding the mouse on the top row (or below the
  last one) scrolls while you choose.
- Ctrl+C copies the chosen text again. Esc lets go of the choice.
- The text goes to the clipboard with `pbcopy` on a Mac, or `wl-copy`, `xclip` or `xsel` on Linux. Over SSH it
  goes through the terminal (OSC 52). Most terminals still offer their own selection while you hold a key as
  you drag (Shift in most, Option in iTerm2).

## Keys

- **Esc** closes the `/` list, or stops an answer that is arriving. It never leaves the chat, so a stray press is harmless. Use `/quit` or Ctrl+C to leave.
- **Ctrl+C** leaves the chat.
- **?** (when nothing is typed) or **F1** opens a card that lists every key. On a short window it scrolls with
  the arrows.

The terminal is put back the way it was when you leave, also after an error.

## Thinking

Models that think show it. While one thinks, a dim `Thinking` block streams its reasoning, the last four rows
of it, so the screen does not jump. When the answer or a tool call starts, the block becomes one line, `✻ Thought for 3s`,
like a tool call's `⏺` line. Click it, or press **Ctrl+O** (which opens the latest tool call or thought), to
read the whole reasoning, and use the arrows to walk between calls and thoughts. Each phase of thinking in a
turn has its own line, and they stay when you scroll back. The reasoning is only shown: it is never sent back
to the model.

## The line chat

`imp chat --plain` is the line chat. It is also used when the input or output is not a terminal, for example
in a pipe. Answers go to standard output. Everything else (tool calls and notes) goes to standard error:

```sh
echo "Summarise notes.txt in one line" | imp chat --plain > summary.txt
```

In the line chat, thinking shows as two lines on standard error, `✻ Thinking…` and then `✻ Thought for 3s`.
The reasoning text itself is not printed.

The line chat has no `/` list and no keys to move through what you sent. Commands and custom commands work
the same way as in the full-screen chat.

## Colours, language and size

- The colours follow the Imp's mark. Set `NO_COLOR` to turn colours off.
- The text is in English, Spanish and Simplified Chinese. It follows `LC_ALL`, `LC_MESSAGES` or `LANG`.
- Nothing is wider than the terminal, down to 36 columns. On a short terminal the message field loses its blank
  rows and the picture of the Imp is left out.
