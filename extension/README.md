# Imp browser extension

The extension lets the Imp Mac app know which page you are on, and where things are on it, so Imp can move to an "Add to Cart" button.

One folder works in every browser: Chrome and the browsers built on it (Brave, Edge, Vivaldi, Opera), Firefox and Safari. In the app, Settings › Tools › Browser › folder button shows the folder (`extension` in the source).

## Install

Start Imp before or after the extension. The extension connects by itself, and it finds Imp again within a minute when Imp restarts.

### Chrome, Brave, Edge (121 or later)

1. Open `chrome://extensions` (or `brave://extensions`, `edge://extensions`).
2. Turn on **Developer mode**.
3. Click **Load unpacked** and pick this folder.

### Firefox (142 or later)

1. Run `./make-firefox.sh` in this folder. It writes the Firefox build to `build/extension-firefox` at the top of the repository. The script changes the manifest's background entry, because Firefox takes `scripts` where Chrome takes `service_worker`.
2. Open `about:debugging#/runtime/this-firefox`.
3. Click **Load Temporary Add-on…** and pick `build/extension-firefox/manifest.json` in the repository.

Firefox removes a temporary add-on when it quits, so load it again after a restart.

### Safari

1. In Safari › Settings › Advanced, turn on **Show features for web developers**.
2. Run `./make-firefox.sh` (as for Firefox above).
3. In Safari › Settings › Developer, click **Add Temporary Extension…** and pick `build/extension-firefox`.
4. In Safari › Settings › Extensions, select **Imp** and allow it on every website. It needs that to read a page or find a button on it.

Safari removes a temporary extension when it quits or after 24 hours. Keeping it for good takes an app signed by an Apple developer account. `xcrun safari-web-extension-packager` makes the Xcode project for that app. The Imp project isn't signed by Apple.

## The popup

Pin the extension to the toolbar to see how it's doing. The popup shows:

- **The Imps that are out.** Each one has its own colour. It follows your pointer with its eyes, blinks, thinks while it works, and shows what it is doing. An Imp out on your iPhone says which device it is on. When Imp isn't running, the Imps fall asleep.
- **The tab in front**, and whether Imp can look inside it. The browser's own pages and its extension store are out of reach.
- **Recent activity**: what Imp lately did on a page, such as reading it or finding "Add to Cart". The list is kept only in memory, so it is cleared when the browser puts the extension to sleep.

**Open Imp** opens Imp's window and starts Imp if it isn't running. The round arrow reconnects. While Imp isn't running, the toolbar icon shows a "!" badge.

## The look and the words

The popup follows Pebble, the design language in `docs/design`. It has one flat surface, soft pebbles without outlines or dividers, monochrome chrome, and one primary action, **Open Imp**. Only the Imps carry colour. The popup has a fixed width of 380 px, one inset for the header, the pebbles and the footer, and one gap between groups. A "?" button beside the page and the list opens a short help tip.

The popup follows the browser's light or dark appearance and Reduce Motion. Every control is a real button or link at least 28 px in size, with a focus ring. The connection status is a live region.

Colours, sizes, radii and timings of the popup's chrome come from `tokens.css`. Every word comes from `_locales` through `chrome.i18n`, in English, Spanish and Simplified Chinese. The Imps' own drawing colours and a few timing constants live in `imp.js` and `popup.js`.

`tokens.css` and `_locales` are generated, so don't edit them by hand. To change them, edit `design/tokens.json` or `design/strings/extension.json`, then run `make tokens` (or `node design/generate.mjs`).

## Permissions

| Permission | Used for |
| --- | --- |
| `tabs` | Reading the URL, title and icon of the tab in front, and opening Imp's link in that tab |
| `scripting` | Running the find and read functions in a tab, only when Imp asks |
| `alarms` | Waking the extension every 30 seconds, so it can connect after Imp starts |
| Host access: `http://*/*` and `https://*/*` | Running those functions in web pages, which `activeTab` can't cover for a background request |

## Messages

The extension and Imp exchange these JSON messages over the WebSocket. The popup and the background script also use a separate port, named `popup`, to exchange the state and a `reconnect` request.

| Direction | Message | Purpose |
| --- | --- | --- |
| Extension to Imp | `hello` (`browser`) | Names the browser when the connection opens |
| Extension to Imp | `page` (`url`, `title`) | The active tab, when it changes |
| Extension to Imp | `pong` | A keepalive, every 20 seconds |
| Extension to Imp | `located` (`id`, `rect`) | The answer to `locate` |
| Extension to Imp | `text` (`id`, `text`) | The answer to `text` |
| Imp to extension | `troupe` (`imps`) | The Imps that are out, for the popup to draw |
| Imp to extension | `locate` (`id`, `query`) | Find one element on the page |
| Imp to extension | `text` (`id`, `limit`) | Read the page's visible text |

## What it sends

Everything stays on your Mac. The extension talks only to `ws://127.0.0.1:47823`, and before each connection attempt it makes one plain HTTP request to the same port. Imp accepts a connection only when the browser sends an extension origin (`chrome-extension://`, `moz-extension://` or `safari-web-extension://`), so web pages are refused.

- Always: the **URL and title of the active tab**, when it changes, and the browser's name when it connects.
- Only when Imp asks: the **on-screen position of one element** that matches a CSS selector or a text. The page scrolls that element into view if it is off screen. Or the page's **visible text**.

Imp tells the extension only which Imps are out: their names, colours, looks and moods, their status (`working`, `idle` or `asleep`), and the name of the device an away Imp is on. The popup draws them from this.

No other page content is read. Nothing is injected up front. A small function runs in the active tab only when Imp asks. The popup also loads the tab's site icon from the site itself, as the browser does for its tab strip.

## Limits

The browser's own pages (`chrome://`, `about:`) and its extension store can't be scripted. Positions are an estimate. The popup assumes the primary display's coordinates, and it works out the page zoom from the ratio of the window's outer and inner width. Fullscreen video and unusual toolbars can be a few points off.
