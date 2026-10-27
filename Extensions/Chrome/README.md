# Imp browser extension (Chrome, Arc, Brave, Edge)

Lets the Imp desktop app know which page you're on, and where things are on it, so it can hop onto an "Add to Cart" button.

## Install

1. Open `chrome://extensions` (or `arc://extensions`, `brave://extensions`, `edge://extensions`).
2. Turn on **Developer mode**.
3. Click **Load unpacked** and pick this folder (`Extensions/Chrome`).
4. Start Imp. The extension connects by itself and reconnects if Imp restarts.

## What it sends

Everything stays on your Mac: the extension talks to `ws://127.0.0.1:47823`, and Imp only accepts connections whose origin is a browser extension (web pages are refused).

- Always: the **URL and title of the active tab**, when it changes.
- Only when Imp asks: the **on-screen position of one element** matching a text, or the page's **visible text**.

No page content is read otherwise. Nothing is injected up front: a small function runs in the active tab only when Imp asks, which is why the extension needs the `tabs` and `scripting` permissions plus http(s) host access (Chrome's `activeTab` only covers a user click on the extension, which can't work for a background request).

## Limits

Pages like `chrome://` and the Web Store can't be scripted. Positions assume the primary display's coordinates and page zoom as reported by the browser; fullscreen video and unusual toolbars can be a few points off.
