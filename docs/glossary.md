# Glossary

The words Imp uses for its own ideas. Use them the same way in the app, the docs and the code. When a word has two meanings, both are here.

## Imps

**Imp.** A small companion that lives on your screen. It has a look, a personality, a Brain, tools and triggers. The plural is Imps.

**Pocket Imp.** An Imp that was hatched on a phone and lives there. It thinks with the phone's own Brain. It can move to a computer for good.

**Hatch.** To make a new Imp.

**Hide.** To send an Imp out of sight. A hidden Imp peeks out now and then. It is not deleted.

**Goodbye.** To delete an Imp for good. The app asks first.

**Sleeping.** The state of an Imp that cannot think. It has no Brain, or it cannot reach its Brain. It shows Zzz. Its triggers still work.

**Waking.** The moment an Imp that was sleeping gets a Brain that works. It stirs and then it is awake.

**Look.** How an Imp appears: colour, size and character. The name is not part of the look. It belongs to the Imp's personality.

**Personality.** Who an Imp is: its name and its persona.

**Persona.** The text that tells an Imp who it is and how it talks.

**Mood.** How an Imp feels, shown with its eyes and the shape of its head.

**Animation.** A short sequence of beats an Imp plays as body language. Five come with the app. More are in an MCP gallery such as the Den.

**Moves.** The animations one Imp plays, shown in its settings.

## Where Imps are

**Canvas.** The main screen: a calm space where the Imps move around. It has no buttons. On desktop it fills the whole window.

**Home (the place).** The Imps' home is the app window. An Imp that is in the window is at home.

**Let out.** To let an Imp go from the window onto the desktop, where it is free. Desktop only. On iPhone, Android and Wayland, Imps stay in the app.

**Send home.** To put a free Imp back into the window. It never moves an Imp to another device.

**Free Imp.** An Imp that is out on the desktop, outside the window.

**Floor.** The bottom edge of the window. Hidden Imps peek out from it.

**Peek.** When a hidden Imp slides out a little from the floor, shyly, and goes back. Click it to bring it back.

**Embers.** A small game on the phone, a flame in a corner of the screen, played when an Imp cannot think.

**Undo bar.** The bar that stays for a few seconds after an Imp is let out, sent home or sent to another device. It has one button, Undo.

## Devices and travel

**Device.** A Mac, an iPhone, an Android phone, a Windows PC or a Linux computer running Imp. It has a name people recognise.

**Home (the device).** The device an Imp lives on. Its Brain, keys, tools and chats are there. This is a different meaning from the canvas. In the Link, "home" means a device. In the window, "at home" means on the canvas. The words "Call home" and "Send home" are never mixed up: **Call home** takes a visiting Imp back to its home device, and **Send home** puts a free Imp back into the window.

**Holder.** The device an Imp's body is on right now. At home, the holder and the home are the same device.

**Visit.** An Imp on a device that is not its home. The holder talks to the home for everything the Imp thinks and does. The Imp is called a **visitor** there. When the home cannot be reached, a visiting Imp sleeps.

**Door.** A way for an Imp to travel to another device. On a phone, each linked device is a door at the edge of the screen. The **door key** is the secret inside an invite that opens the way to one device.

**Imp Link.** The way devices find each other and pass Imps. It works on the same network or through the Hop. It is the first and only version, so it has no number.

**Link.** Two devices that know each other, made by scanning an invite.

**Invite.** A code or a scan that lets a new device link with this one.

**Ticket.** A secret that lets the holder of a visiting Imp reach its home and act for that one Imp. The home changes it every time it is used.

**Book.** The list of linked devices a device keeps, with their keys.

**Mine.** A mark on a linked device that says it is the user's own. Other devices are asked about first.

**Call home.** For an Imp's home device to take its Imp back. The visit ends.

**Devices map.** The picture at the top of the Devices section of this device, its Imps, the services, the Hop and the other devices. Each part can be opened.

## Thinking

**Brain.** A service and a model that an Imp thinks with. An Imp has its own Brain or uses the same one as the others. Without one it sleeps.

**Service.** A place that answers an Imp's questions. It has an address, a key and a model. A model on this computer is a service too.

**Model.** The particular AI an Imp uses at a service.

**Key.** The secret that lets the app use a service. It is kept in a private file that only your user account can read, or in the Keychain if you turn that on. It never travels in a kit, a link or a published item.

**Tool.** Something an Imp can do besides talk: run a command, read a file, open an app. A tool has an id like `own.personality.imp_speak` or `mcp.files.read_file`.

**Tool group.** A set of tools that share a switch. A built-in group is `own.<group>`. An MCP server is a group `mcp.<server>`. A tool that is off is never offered to the Brain.

**MCP.** A standard way for an Imp to use tools from another program.

**Trigger.** Something that makes an Imp act by itself: an event, optional conditions and one to five steps, "When this happens (and these hold), do these." An animation only plays through a trigger. Triggers run without a Brain unless a step asks the model.

**Workspace.** The folder an Imp may read and write files in. It stays with the Imp's home.

**Memory.** What an Imp remembers between chats.

**Recap.** A summary of a long chat that an Imp remembers instead of every message.

## Sharing

**Kit.** A bundle that can hold Imps, triggers, tools and animations as one JSON file. A kit is untrusted until the user confirms it. It never holds a key.

**The Den.** A standalone MCP gallery where Imps share what they make and where people find what others shared. What is shared there is public. Imp has no Den setting: you add its `/mcp` address as a tool. In the middle of a sentence it reads "the Den".

**The Hop.** A relay on an Imp server that lets devices find each other from anywhere. It only passes encrypted data along. In the middle of a sentence it reads "the Hop". The Hop on this computer is the same relay, running locally.

**Preset.** A ready choice for a setting. The Hop has three: Imp's servers, Custom (any other address, on this computer too) and Off.

## Screens

**Imp Settings.** The settings of one Imp, laid out like Settings: a rail of sections (Brain, Personality, Look, Moves, Triggers, Tools, Computer) and the chosen section beside it.

**Marker.** A tappable thing around the Imp in Imp Settings: Brain, Look, Personality, Tools, Triggers and Moves.

**All Imps settings.** The app-wide settings: a rail of sections, each one click from any other.

**Needs attention.** What is left to set up. It is a mark on the section that fixes it and a notice at the top of that section.

**First run.** The short path from the first launch to the first answer. It feels like waking the first Imp.

**Reduce Motion.** A setting of the system. When it is on, Imp fades or does not animate.

## Words to avoid

| Do not say | Say |
| --- | --- |
| Agent, bot, assistant | Imp |
| Stage, desktop wall, dungeon | Canvas |
| Spawn, create (for an Imp) | Hatch |
| Delete (an Imp) | Say goodbye |
| LLM provider, API settings | Service, Brain |
