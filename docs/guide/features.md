# Features

Imp is a desk companion. It floats above your windows, watches your cursor and shows how it feels
with the shape of its head and eyes. Click it, type or talk to it, and it answers.

It has one tool to start with: a **shell** on your Mac. Ask it to open an app, rename a pile of
files, read a document or call a web API, and it works out the commands itself.

## Talk, type or click

Ask out loud or type. Answers show up in a speech bubble. The full chat lives in the bubble. See
[the chat bubble](/concepts/bubble).

## Triggers

A trigger is an event, optional conditions and one to five steps: when it happens (and the conditions
hold), the Imp runs the steps in order. It is the only way an Imp does anything by itself. An event can be:

- **You**: keys you set, clicks on the Imp (one click opens its chat bubble, two or three run your click triggers), a gesture with the pointer (4 quick clicks, press and hold, drag, let go, shake, stroke, tickle, circle, swish, rush, bob above its head), the pointer coming close or moving away.
- **Time**: the Imp starts, a time of day, every few minutes, nobody has touched it for a while, you come back to your desk, the Mac wakes.
- **Your Mac**: an app comes to the front, a website opens, the battery runs low, the charger is plugged in or out, the processor is busy, the Mac runs hot, the network drops or returns.

Add conditions such as *only if on battery*, *only between 22:00 and 07:00*, *only Monday to Friday* or *only while it is asleep*.

A step can ask the Imp's model (with what you copied, if you like), say something (aloud too), play one of its animations, fall asleep, wake up, follow the cursor, or open the text box, the chat, the settings or listening. Example: *poke → play Wiggle, say "Ouch!"*. Add them in Settings, Triggers.

A new Imp has no triggers to start with. Steps that act on the Imp's body need no model at all: fall asleep, wake up, play an animation, or **follow the cursor**. Follow takes a mode (Off, Eyes, Hop or Glide) and a speed. Without a follow trigger an Imp's eyes follow the cursor and its body stays. To have it hop after your cursor, add a trigger *Imp starts → follow the cursor, Hop*, or just tell it "follow my cursor". With Reduce Motion on, Hop and Glide become Eyes. This is for the Mac: the iPhone has no cursor.

## Long memory and chats you never lose

- **Remembers** (Brain › Memory) sets how many past exchanges go to the model with each message: 5 to 1,000,
  or no limit. The default is 20. Imp keeps at most 1,000.
- When a chat grows long, **Recap** has the model sum it up. The recap becomes the chat's opening exchange, after
  the system prompt, which is never changed. Recapping again folds the old recap into the new one.
- Every chat stays in Brain › Memory › Chats. Continue an older one, save it as a file, or import one to
  carry on with any Imp, on any Mac.
- The chat bubble loads long chats a page at a time as you scroll up.

## It sets itself up

Ask Imp for something new and it can add the MCP server it needs, open its settings for you to fill in a
key, and create the trigger, then show you how it works.

## Body and senses

Imp plays its animations as body language: it hops, slides or bounces around the screen, speaks out loud,
reads how the Mac is doing, and messages the other Imps. Each of these tools can be switched off per Imp,
behind the wand button of the section it belongs to (Moves, Personality, Look, Triggers, Tools, Computer).

## Make your own animations

**All Imps › Animations** lists every animation, with a search box. **New Animation** opens an editor: a stage
to preview the face, a list of beats on a timeline (each beat is a pose held for a while, with a mood, tilt,
hop, symbol and an optional move that can play either way round).

- An animation is for every Imp, or for one Imp alone. The one Imp's wins over a shared one.
- Imps make animations too: they use `imp_make_animation`, `imp_show_animation` and `imp_remove_animation`.
- **Export as Sticker…** (the smiling-face button on an animation, or its right-click menu) saves it as an animated
  sticker, `.tgs`: the Imp acting it out in its colour and character, as vectors (Lottie), 512 × 512 at 60 frames a
  second, at most 3 seconds and 64 KB. A longer animation plays up to twice as fast and stops at 3 seconds; the save
  panel says so.

The format, with every mood, glyph and move, is in the [Kit format reference](/sharing/kits#animations-and-traits).

## A character of its own

Each Imp's **Look** section sets how it always looks and moves: lids, brows, eye size, squint, horns, blush,
head tilt and tempo. Start from a preset (such as Tired, Grumpy, Worried, Sly, Lazy or Jittery) or use the
sliders. The look shows in every mood and animation. The Imp can set it itself (`imp_set_traits`), and its
**Moves** section lists the animations only that Imp plays. The ranges are in the [Kit format reference](/sharing/kits#animations-and-traits).

## Backgrounds

Ask any Imp for a background ("floating clouds", "a starry sky", "a poker room with a seat for each of us") and it
draws one behind all the Imps: a small web page with CSS, SVG or a canvas, animated if you like
(`imp_set_background`, and `imp_show_background` to build on the one there now). It starts as one plain colour.
The Mac's canvas and the iPhone's room each have their own. File › Reset Background puts the plain one back on the
Mac. Each Imp may be stopped from changing it with the wand in its **Look** section.

## Computer control (optional, off by default)

Switch it on per Imp in its **Computer** section and the Imp can operate any app, such as a browser or Photoshop.
It looks at the window (a screenshot plus the accessibility tree), clicks, types, uses shortcuts and menus,
scrolls and draws, then checks the result.

It needs two permissions: **Screen & System Audio Recording** and **Accessibility** (Device Control & Data
Access). The Imp's Computer section shows what is missing, with buttons. If it still doesn't work after granting, remove
Imp from the list, add it again (+), then restart Imp.

Try the element tree without a model:

```sh
Imp --observe Finder [--screenshot out.png]
```

## Browser extension

Add the `extension` folder to Chrome, Brave, Edge, Firefox or Safari and Imp knows the website you are on,
and can hop right onto a button on the page. Its toolbar popup shows whether it is connected and what Imp
sees. It works locally only. See [`extension/README.md`](https://github.com/impsland/imp/blob/main/extension/README.md)
for each browser's steps.

## Imps on your other devices

Throw an Imp hard at the left or right edge of your screen and it can fly onto your iPhone, another Mac or
a friend's device, and keep thinking at home. Read [Imps on other devices](/connecting/phone).

## More tools with MCP

Connect Model Context Protocol servers, local or on the web. A web server that asks you to sign in (the Den,
for one) works too: in **Tools**, the server shows **Sign in**, which opens its own sign-in page in a browser
sheet, and **Sign out** once you have. When you add a server or switch it on and it asks you to sign in, the sheet opens
at once and you can cancel it; Imp never opens it by itself (at start-up, on a background reconnect, or when an Imp arrives from another device), and the server then shows
**Sign-in needed**. Until you sign in, an Imp sees one stand-in tool for the server: when you ask it to use
the server, the sheet opens and the real tools replace the stand-in. On iPhone the sheet opens only while
Imp is in front. The sign-in is kept with your API keys, in a private file by default or in the
Keychain if you switch that on.

## A whole troupe

Run several Imps, each with its own name, colour, personality and model. They share one clock and stop
drawing whenever they can't be seen, so a big troupe stays light on the battery.

## Your language

English, Spanish and Simplified Chinese, following your Mac. Or pick one for Imp alone in
**All Imps › App › Language**, the same setting as **System Settings › General › Language & Region ›
Applications**. It applies after a restart, and **Restart Now** is right there.

## Automation

Imp answers `imp://` links, so Shortcuts, Raycast and scripts can use it. See [Automation](/guide/automation).

## Share setups

Send an Imp, its triggers and its tools to a friend as one JSON file or a link. See [Sharing setups](/sharing/setups)
and [The Den](/sharing/den).
