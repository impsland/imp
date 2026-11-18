# Automation

Imp answers `imp://` links. Use them from Shortcuts, Raycast, Alfred, a script or a web page.

| Link                                       | Does                         |
| ------------------------------------------ | ---------------------------- |
| `imp://ask?text=…&imp=Pip`                 | Asks an Imp something        |
| `imp://run?action=Translate%20clipboard`   | Runs one of your triggers    |
| `imp://talk`                               | Starts listening             |
| `imp://type?text=…&send=1`                 | Opens the text field (`send=1` sends it) |
| `imp://settings`                           | Opens Imp's window (optional `setting`, `page`, `imp`) |
| `imp://add?url=https://…`                  | Opens a kit to review        |
| `imp://add?kit=<base64url JSON>`           | Opens a short kit to review  |

`imp://run` runs one of your triggers by name, so a trigger can be started from outside too, whatever its
event. A trigger is an event, optional conditions and one to five steps (for example *poke → play Wiggle, say
Ouch*); see [Features](/guide/features#triggers).

Each link needs its key: `ask` needs `text`, `run` needs `action`, and `add` needs `url` or `kit`.
Values must be URL-encoded (a space is `%20`). A kit link never adds anything by itself: Imp always shows
the kit for you to review first. See [Sharing setups](/sharing/setups).

Open a link from Terminal to try it:

```sh
open "imp://ask?text=What%20time%20is%20it%3F"
```
