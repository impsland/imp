# Features

Imp is a desk companion. It floats above your windows, watches your cursor and shows how it feels
with the shape of its head and eyes. Click it, type or talk to it, and it answers.

It has one tool to start with: a **shell** on your Mac. Ask it to open an app, rename a pile of
files, read a document or call a web API, and it works out the commands itself.

## Talk, type or click

Ask out loud or type. Answers show up in a speech bubble. The full chat lives in the bubble. See
[the chat bubble](/concepts/bubble).

## Triggers

When something happens, Imp gets your instruction together with what happened, and its model decides
what to do. Triggers can fire on:

- **Keys**: on what you copied (text or a picture).
- **Clicks** on an Imp. One click opens its chat bubble. A double click opens its settings by default (you can
  make it talk, or nothing). Three or more clicks run the Imp's click triggers.
- **Your Mac**: the battery runs low, the charger is plugged in, an app comes to the front, a website
  opens, a time of day arrives, every few minutes, you come back to your desk, the Mac wakes, gets busy
  or hot, or the network drops.

Add conditions such as *only if on battery* or *only between 22:00 and 07:00*.

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
reads how the Mac is doing, and messages the other Imps. Each group of these tools can be switched off
per Imp, in the Imp's **Tools** tab.

## Make your own animations

**All Imps › Animations** lists every animation, with a search box. **New Animation** opens an editor: a stage
to preview the face, a list of beats on a timeline (each beat is a pose held for a while, with a mood, tilt,
hop, symbol and an optional move that can play either way round).

- ✎ on a built-in animation makes your own version, which plays instead of it.
- An animation is for every Imp, or for one Imp alone. The one Imp's wins over a shared one.
- Imps make animations too: they use `imp_make_animation`, `imp_show_animation` and `imp_remove_animation`.

The format, with every mood, glyph and move, is in the [Kit format reference](/sharing/kits#animations-and-traits).

## A character of its own

Each Imp's **Moves** tab sets how it always looks and moves: lids, brows, eye size, squint, horns, blush,
head tilt and tempo. Start from a preset (such as Tired, Grumpy, Worried, Sly, Lazy or Jittery) or use the
sliders. The look shows in every mood and animation. The Imp can set it itself (`imp_set_traits`), and the
tab lists the animations only that Imp plays. The ranges are in the [Kit format reference](/sharing/kits#animations-and-traits).

## Computer control (optional, off by default)

Switch it on per Imp in its **Tools** tab and the Imp can operate any app, such as a browser or Photoshop.
It looks at the window (a screenshot plus the accessibility tree), clicks, types, uses shortcuts and menus,
scrolls and draws, then checks the result.

It needs two permissions: **Screen & System Audio Recording** and **Accessibility** (Device Control & Data
Access). The Tools tab shows what is missing, with buttons. If it still doesn't work after granting, remove
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

Connect Model Context Protocol servers, local or on the web.

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
