# Skills and commands in the apps

The Mac app and the iPhone app use the same skills and custom commands as the terminal chat
([skills](/apps/cli-agents), [custom commands](/apps/cli-commands#custom-commands)). The rules are written once, in
the core (`engine/src/agents.rs` and `engine/src/custom.rs`), and the three apps call them: what a command is, how
its text is filled in and split, how the skills are listed and read.

## Where the files are

| App | The `.agents` folder |
| --- | --- |
| `imp` | `~/.agents` and the `.agents` of the folder it runs in |
| Mac | `~/.agents` |
| iPhone | `.agents` in the app's Documents folder (the Files app and Finder show it, with Imp's file sharing). Imp makes `skills` and `commands` there |

The app reads the folder again when a text box opens, so a new file is there the next time you type `/`.

## Skills

- The Imp's system text lists the skills (name and what each is for), as in the terminal chat.
- The `use_skill` tool reads one. It is in the own tool group **Skills**, which an Imp can switch off like the
  others (Tools tab on the Mac). Off, the skills are not listed and the tool is not offered.
- On the Mac the tool goes through the Imp's rules like any other: the action is `skill` and the resource is the
  skill's name, so `skill review deny` or `ask` works as it does in the terminal.
- The iPhone has no rules, so `use_skill` runs when the Imp calls it. An Imp can have the tool switched off.

## Commands

Type `/` in the text box (the bubble's, or the chat's). The commands show in a small list: the name, `ARGUMENTS`
when its text takes them, and what it does. The list narrows as you type.

| | Mac | iPhone |
| --- | --- | --- |
| Pick | Up and Down, Tab or Return | Tap |
| Close | Esc | Delete the `/` |

Return on a command with no arguments sends it. Sending `/name arguments` makes the text the same way as the terminal
chat does (`$ARGUMENTS`, `$1` to `$9`, `` !`cmd` ``, `@path`) and sends it as the message. The Mac chat shows what you
typed; the iPhone chat shows the message the command made.

| | Mac | iPhone |
| --- | --- | --- |
| `` !`cmd` `` | Runs in the Imp's own folder, behind the `shell` permission (the person may be asked) | There is no shell: the command stops with "`cmd` can't run here: this device has no shell." |
| `@path` | Reads the file behind the `read` permission. A word that names no file stays as typed | Reads a file inside the Documents folder (`~/path` or `path`). Any other word stays as typed |
| `agent` | That Imp answers, with its own rules | That Imp of this iPhone answers |
| `model` | For this message only, when the provider is one of the Mac's services (the variant, `#high`, is not a setting of the app) | The model's name, on the Imp's own service |
| `subtask` | A conversation of its own: the answer is shown in the bubble and is not kept | The chat shows the answer; the Imp does not remember it |

A command or a file that is not allowed stops the command and says why. Nothing is sent. A command that names an
Imp or a model that is not there says so. A visiting Imp thinks at its home, so on the iPhone `agent`, `model` and
`subtask` apply to the Imps that live on the iPhone only: for a visiting Imp the message is sent as the command made it.
