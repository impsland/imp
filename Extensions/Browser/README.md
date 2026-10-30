# Imp browser extension (Chrome, Brave, Edge, Firefox, Safari)

Lets the Imp desktop app know which page you're on, and where things are on it, so it can hop onto an "Add to Cart" button.
One folder works in every browser: Chrome and the browsers built on it (Brave, Edge, Vivaldi, Opera), Firefox and Safari.
In the app, Settings › Tools › Browser › folder button shows it (`Extensions/Browser` in the source).

## Install

Start Imp first or afterwards: the extension connects by itself, and finds Imp again within a minute when Imp restarts.

**Chrome, Brave, Edge** (121+)

1. Open `chrome://extensions` (or `brave://extensions`, `edge://extensions`).
2. Turn on **Developer mode**.
3. Click **Load unpacked** and pick this folder.

**Firefox** (142+)

1. Open `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on…** and pick `manifest.json` in this folder.

Firefox removes a temporary add-on when it quits, so load it again after a restart.

**Safari**

1. In Safari › Settings › Advanced, turn on **Show features for web developers**.
2. In Safari › Settings › Developer, click **Add Temporary Extension…** and pick this folder.
3. In Safari › Settings › Extensions, select **Imp** and allow it on every website (it needs that to read a page or find a button on it).

Safari removes a temporary extension when it quits or after 24 hours. Keeping it for good takes an app signed by an
Apple developer account (`xcrun safari-web-extension-packager` makes the Xcode project); Imp isn't signed by Apple.

Pin it to the toolbar to see how it's doing: the popup says whether Imp is connected and what Imp has been told
about the tab you're on, with a **Reconnect** button. While Imp isn't running the icon shows a small "off" badge.

## What it sends

Everything stays on your Mac: the extension talks to `ws://127.0.0.1:47823`, and Imp only accepts connections whose origin is a browser extension (web pages are refused).

- Always: the **URL and title of the active tab**, when it changes.
- Only when Imp asks: the **on-screen position of one element** matching a text, or the page's **visible text**.

No page content is read otherwise. Nothing is injected up front: a small function runs in the active tab only when Imp asks, which is why the extension needs the `tabs` and `scripting` permissions plus http(s) host access (`activeTab` only covers a user click on the extension, which can't work for a background request). The `alarms` permission wakes it every 30 seconds while Imp isn't connected, since browsers put an idle extension to sleep.

## Limits

A browser's own pages (`chrome://`, `about:`) and its extension store can't be scripted. Positions assume the primary display's coordinates and page zoom as reported by the browser; fullscreen video and unusual toolbars can be a few points off.
