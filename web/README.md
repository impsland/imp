# Imp on the web

A web page that is one of your devices on [Imp Link](../docs/connecting/link.md). Throw an Imp off the
side of a Mac's or iPhone's screen, or `/send Web` it from the terminal app, and it lands on the page.

The page looks like the Mac app's home: one plain surface, dark or light with the system, and nothing on it
but the Imps. Empty, it has one **Connect** button. With Imps on it, a **+** in the top right corner connects
another device. Connecting is a camera that reads the other device's code and a box to paste it in.

- **Resize** the chat by its sides and corners, as on the Mac. It first opens at its smallest, next to its Imp.
  Moved by its top or resized, it leaves the Imp and keeps its size and place for the next time, for every Imp.
- **Click** an Imp to talk: the same bubble as on the Mac (a text box, then what it is doing, then the answer).
  The corner buttons open the whole chat, reply and copy. **Right click** for Poke, Cuddle, New chat and Send home.
- **Photos, sound and video**: the **+** in the bubble's text box takes a photo, records a sound or picks
  files (4 at most, 25 MB each). Drop files on an Imp or its bubble, or paste a picture. They go to the Imp's
  home before the question (`upload`, see "Attachments" in the Link docs). Sound is sent as WAV.
- **Take a photo** opens the camera full screen. The Imps on the page run to its corners and peek in from the
  edges; carry them anywhere over the picture. The photo has them where they stand, and can be retaken,
  saved or sent. While the camera is open nothing is thrown off the page.
- **Hold** it to cuddle it, **shake** it while carrying.
- **Carry** it anywhere. Only a hard fling at a side throws it to the device that side leads to, by the
  Mac's rule (a fast sideways push at the side while still carrying; letting go never throws) or, with a
  finger, the iPhone's (a flick that would carry it off the page). See `app/toss.js`. Rest it near a side for
  half a second and the doors show, as on the Mac: a band per device the side leads to, the one a throw at
  that height goes to lit, or "Nobody here".
- **Reload** the page and the Imps stay where they were: their visits are in the book, and their homes
  tell the page everything again when it reconnects.

The page only holds the Imp's body. The Imp keeps thinking on its home (the Mac, iPhone or computer it was
hatched on): its model, keys, tools and chats never leave that device. This is the Link's **visit**, the same
as when an Imp visits another Mac. Its tools run there too: the bubble shows what it is doing while it
works and the steps it took under the answer. A home that doesn't count the page as the owner's (Mine) lets
its Imp only talk here, and the bubble says so.

Imps on the page talk to each other and to the Imps on your other devices: the page tells every device
which Imps are on it (`stage`), and forwards what one Imp says to another's home (`message`, `answer`).
What an Imp says to another shows in a small bubble beside it.

## How it works

- `link/` is the link node of `imp-engine` (`Node`) compiled to WebAssembly. It runs the same Noise
  handshake, access rules, tickets and book as the apps and the terminal app, so the other devices see an
  ordinary linked device and need no change.
- `app/link.js` carries the node's bytes. A browser can't open TCP, so every connection is a WebSocket:
  to the Hop, which takes WebSockets on its own port (`server/hop/src/ws.rs`, `spec/PROTOCOL.md`), or
  straight to a device that takes them on its link port (none does yet).
- `app/app.js` is the page. It draws Imps with the Den gallery's renderer (`server/den/web/assets/imp.js`),
  which the build copies in. `app/toss.js` tells a throw from a carry, `app/connect.js` reads and joins a code.
- The camera reads codes with the browser's `BarcodeDetector` where there is one, else with `scan_qr` in the
  link node (the `rqrr` crate), so it works in Safari and Firefox too.

The book (the page's links and its secret seed) is kept in the browser's `localStorage` for this site.
Anyone who can read this browser's storage can act as this device: **Forget every device** (in Link a
device (Forget on the Mac or iPhone) undoes the links on that side, and clearing the site's data in the
browser undoes them here.

## Build and run

```sh
make web                                  # or web/build.sh: builds app/pkg
python3 -m http.server 8099 -d web/app    # any static file server
```

Open `http://localhost:8099/`. The build needs rustup's toolchain with the `wasm32-unknown-unknown`
target, clang with a WebAssembly backend (`brew install llvm`) and `wasm-bindgen-cli` at the version in
`Cargo.lock` (see the top of `build.sh`).

The address may carry settings: `?name=Kitchen` (what your devices call the page), `?hop=host:port` (a Hop
to wait at), `?hopSocket=wss://…/` (when the Hop's WebSocket isn't at the usual address), and
`#join=implink://…` connects with that code as the page opens.

## Linking

Press **Connect** (or **+**) and hold the other device's code up to the camera, or paste it. On the Mac it is
Devices › Show code, in the terminal chat `/pair` (the line under *as text*). The code must carry a Hop
(`imp chat` and `imp link` take it from `IMP_HOP`, `imp qr` from `--hop`). The camera needs a page opened
over `https://` or from `localhost`; elsewhere paste the code. If the other device doesn't answer (an iPhone
whose link was copied into Safari is in the background), the window waits for it for three minutes and links
as soon as Imp is open on it again. On a phone the window is a sheet from the bottom.

A page needs a Hop that takes WebSockets, which is this version of the Hop:

| The page is opened from | The Hop's WebSocket |
|-------------------------|---------------------|
| `https://…` | `wss://<hop host>/`, through a proxy that ends TLS (see `server/README.md`) |
| `http://…` (your computer or your network) | `ws://<hop host>:<port>/`, the Hop itself |

### On your own Wi-Fi

Run a Hop on a computer on the network, `imp serve --host 0.0.0.0`, make `<computer>.local:4677` the Hop
of your devices, and open the page over `http://` from a computer on the same network. Nothing
leaves the network. A browser only refuses `ws://` to your network from a page opened over `https://`.

Going straight to a device without any Hop would need the device to take WebSockets on its link port. The
page already tries that first (`ws://<address>:<port>/` from an http page), but the apps and the terminal
app don't take them yet.

## What it doesn't do yet

- Imps can only visit. The page has no brain, so nothing hatches or lives here, and Imps can't move in.
- Files an Imp mentions aren't fetched. Replies show paragraphs, code and bold, not the rest of Markdown.
- The page doesn't show a code of its own for another device to scan: it connects by reading theirs.
- The list of an Imp's saved chats (`chats`) and its talks with other Imps (`talks`, `talkLines`) aren't
  shown. What an Imp says to another while it happens is.

## Tests

- `cargo test -p imp-web`: two nodes driven the way `link.js` drives them link with a code and pass
  messages, and `scan_qr` reads a code back.
- `node --test web/tests/*.test.mjs`: the throw rules (`app/toss.js`) against the Mac's and the iPhone's.
- `cargo test -p imp-hop --test websocket`: browsers spliced with TCP clients at the Hop, and the limits.
