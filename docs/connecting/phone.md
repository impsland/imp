# Imps on other devices

Imps can travel between your Mac, your iPhone and other devices you link. This page describes what you do and
see. How it works underneath is in [Imp Link](/connecting/link), the shake gesture is in
[Transfer by shaking](/concepts/transfer), and the security model is in [the threat model](/architecture/threat-model).

**Imp for iPhone** (the app in `apple/iOS/`) is where your Imps go when you throw them off your Mac, and where
Imps of its own live. Any device can invite another, and one device can have many links.

## Throwing an Imp

An Imp is never in two places at once.

- Fling it hard at the far left or right edge of your screen, and it leaves the desktop and flies in from the
  *opposite* side of the other device: throw it off the left of the Mac and it comes in from the right of the phone.
- With several displays, only the outer edges throw. Carrying an Imp from one display to the next is just a carry.
- Or right-click it › **Send to**, and pick a device.

### Doors

Where a thrown Imp goes depends on the side.

- An Imp at home can leave by either side, to any device you're connected to.
- A visiting Imp goes back the way it came by the same side, and on to other devices by the other side.
- When a side leads to several devices, it is split into **bands**, one per device. How high you throw picks the band.

While you carry an Imp near an edge, the screen labels the bands with the devices' names, marks the way back as
"back to" its device, and says so when a side leads nowhere. With VoiceOver, use the Imp's **Send to** menu instead.

## On the phone

It's the same Imp, drawn by the same code. Drag it with your finger and tap it to chat. It still thinks on your Mac,
with its model, keys, tools and memory, so you can give it work from the couch. It can also message the Imps still on
your desktop.

To send it back, flick it off a side of the phone's screen, or jolt the phone sideways (see
[Transfer by shaking](/concepts/transfer)). A shake makes the Imps on the phone dizzy. **Call Home**, or clicking the
little phone on its pedestal in the Mac's window, brings a visiting Imp back too.

## Visits

An Imp away from its home keeps thinking there, with its home's model, keys, tools and memory.

- If its home goes away, the visiting Imp falls asleep. Its chat says so and waits, and it wakes when the home is back.
- A visiting Imp's menu has **Chat**, **Talks** and **Send Home**.
- The **Devices** sheet lists, under each device, which of your Imps it holds, each with **Call Home**.
- Passing a visiting Imp to a third device gives that device a ticket. It works for that one Imp only, even if
  the third device isn't linked to the home. Details are in [Imp Link](/connecting/link#tickets).

## Imps hatched on the phone

The first one is the sleeping Imp on the first screen: tap **Wake Imp up** and give it a Brain. After that, tap
**+** at the top of the room: the new Imp appears at once, already thinking with the Brain of your other Imps (its
key is copied, so you never type it again). It lives in your pocket.

- It thinks on the iPhone, using a service you give it (address, model and key) and any web (HTTP) tool servers.
- Keys and header values are kept in the phone's Keychain.
- It works with no Mac linked, or while yours is out of reach. A pocket Imp has no shell, no computer control, no
  triggers, no Mac senses and no Den tools. It can message your other Imps, play its animations and use the tool
  servers you gave it.
- Throw it to another iPhone and it visits there.
- **Move to** `<Mac>…` (in its menu, while a Mac is connected) moves it home for good, with its chats, looks,
  personality, service and tool servers. The Mac shows the usual kit review first. The Imp arrives with its shell
  off, and the phone drops its copy once the Mac confirms. A pocket Imp never comes back.
  - Its service joins the Mac's services under its own name, or matches one already there by address.
  - An Imp with no brain yet moves too, and sleeps on the Mac until you choose a service for it.
  - An Imp that is busy thinking stays until it's done.
- Its Brain is one screen: pick **Remote** (OpenRouter) or **Local** (a service on your Mac, reached by the Mac's
  name on your network, so it still works when the Mac's Wi-Fi address changes), paste the key and tap Wake.
  The model is picked for you, or choose one from the list.
- In its **Tools**, switch **Message another Imp** and **Play animations** on or off, and add tool servers.
- In its **Personality**, **What it's good at** is a line or two the other Imps read to know whom to ask. Its tool
  servers' names go with it as what it can do (no commands on the phone).
- Hold a pocket Imp to open its settings. Changes are kept as you make them.

## Messages and talks

Every Imp messages the others the same way, whether it's on the phone, a pocket Imp or on the desktop (`imp_message`).

- An Imp reaches the Imps of its own device, the Imps on the screen it is on, and the Imps out on your other
  devices.
- For your other devices, each device must mark the other **Mine**, on both sides. Until then the Imps meet only
  when one is thrown onto the other's screen. An Imp asked across devices before that says which device to fix.

A message can wait for the answer or not (the tool's `wait` argument). The phone has no Between-Imps settings: the
Imp chooses each time (the Mac's **Decides** setting). Without waiting, the tool returns a receipt at once and the
answer arrives later as a new message in the Imp's chat ("Bo answered"), which starts a turn of its own: at once if
the Imp is idle, else once it has finished what it is doing. Same limits as on the Mac (`troupe::may_leave`).
The answer is dropped if the Imp was deleted, moved to a Mac or is away on another device meanwhile, and answers still
on their way are lost when the app quits.

The talk shows in bubbles over their heads: the question over the Imp asking, a small "thinking" bubble over the one
asked, then the answer.

- Every talk is kept. An Imp's **Talks** (in its chat's menu, on the Mac and the phone) puts both sides of a
  conversation back together, to read later. As in any messenger, what that Imp said is on the right and what
  the other Imp said is on the left, whichever of them asked, on the Mac and the phone alike (`TalkSide`).
- A voice reply plays with the Imp seen speaking, its bubble glowing with the voice.
- Voices play one at a time, so two Imps never talk over each other. The Imps don't wait for a voice to finish
  before they think.

## Linking

Either device shows a code and the other scans it. On the iPhone, use **Show my code** or **Scan a Code**, or
**Paste Link**. On the Mac, use the Devices card in Imp's settings, and **Scan Code…** there.

- A code works for **15 minutes** after it was last on screen, and several devices can scan it.
- Devices find each other with Bonjour on your Wi-Fi. This needs **Local Network** for Imp (iPhone Settings › Imp).
  When it is off, the card says so and has a button to open Settings.
- The code appears once the iPhone is ready to be reached, and is made again if the Wi-Fi or the server changes.
- The iPhone's name, which other devices see, can be changed on its first screen.

The status pill on the iPhone shows how many devices are connected and opens the **Devices** sheet. It lists the
linked devices (connected, via the server, or away), the Imps each holds, and **Forget…** per device.

- **Forget…** calls your Imps home from that device and sends its visiting Imps home too.
- **Forget Everyone…** also makes every code shown before stop working.

## Trust

Mark your own devices **Mine** in the Devices card or sheet.

- An Imp visiting a device that isn't yours, or asked by an Imp whose home isn't one of your devices, talks but
  doesn't use its tools: no commands, no computer control, no tool servers, no messages to other Imps.
  - The Imp knows why. Asked for something that needs its tools, it says so and points to **Mine** on its home.
  - The iPhone's chat shows "only talks here", with the same fix behind its help icon. It doesn't offer the
    "Ask … to" suggestions there.
- Such a device only gets files from the Imp's own folder.
- A visiting Imp still thinks with its home's model and keys, so whoever you pass it to chats on your service.
- You can call an Imp home at any time, from anywhere. Its home always decides where it is.

## Beyond Wi-Fi

Devices also try each other's addresses on port 47824, so a VPN such as Tailscale works from anywhere.

Without a VPN, set a **Hop** in the Devices sheet (or the Mac's Devices card). A device waits at that Hop, a blind
relay, and the others use it when nothing closer answers. The Hop can't read what passes through it.

To run your own Hop or Den, see `server/README.md` in the repository.

## When the link drops

Both sides notice within 45 seconds, or at once when the phone's network changes, and the phone reconnects on its
own. An Imp that was on the phone stays there and shows up again when the link is back.

If a Mac forgot the phone, the phone says so. One of you then shows a new code to link again.
