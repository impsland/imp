// Imp bridge: tells the Imp desktop app which page the active tab shows, and finds elements or
// reads text on that page when Imp asks. It talks only to 127.0.0.1 on port 47823: a WebSocket,
// and a plain HTTP check on the same port before each attempt.
// One script for every browser: a service worker in Chrome, an event page in Firefox and Safari.
// Either may be put to sleep when idle and woken by an event. Nothing is kept except these
// variables: the Imps Imp last described (sent again on every connection) and a short list of
// what Imp just did. The list is gone when the script sleeps, on purpose.

const api = globalThis.browser ?? globalThis.chrome;
const ADDRESS = "ws://127.0.0.1:47823";
// Sleeping ends timers. An alarm wakes the background again, so an Imp started later is found within a minute.
const WAKE_ALARM = "connect";
// Sends an unprompted "pong" as a keepalive. Socket traffic keeps a Chrome service worker alive (Chrome 116 and later).
const PING_MS = 20_000;
const RETRY_FIRST = 1_000;
const RETRY_LAST = 30_000;
const ACTIVITY_KEPT = 6;

// Everything the popup draws. Pushed to it whenever it changes.
const state = {
  connected: false,   // the socket to Imp is open
  connecting: false,  // an attempt is in flight
  browser: "",
  troupe: [],         // the Imps let out, as Imp described them: [{ name, hue, scale, traits, mood, away, status, device }]
  activity: [],       // what Imp just did on pages, newest first: [{ kind, query, ok, host, at }]
};
const popups = new Set();   // the open popup ports
const browserReady = detectBrowser().then((name) => { state.browser = name; publish(); return name; });

let socket = null;
let backoff = RETRY_FIRST;
let pingTimer = null;
let retryTimer = null;
let lastSent = "";

/**
 * Names the browser for Imp. Firefox and its forks say so themselves. Safari is recognised by the
 * extension's own scheme. Other Chromium browsers are told apart by their brand list.
 * @returns {Promise<string>} The browser's name, such as "Firefox" or "Chrome".
 */
async function detectBrowser() {
  if (api.runtime.getBrowserInfo) return (await api.runtime.getBrowserInfo()).name;
  if (location.protocol === "safari-web-extension:") return "Safari";
  const brands = (navigator.userAgentData?.brands ?? []).map(b => b.brand);
  return ["Brave", "Microsoft Edge", "Vivaldi", "Opera"].find(name => brands.includes(name)) ?? "Chrome";
}

// MARK: Popup

// The popup holds a port open while it's showing: it gets the state at once and again on every
// change (no polling), and its buttons are messages that need no answer.
api.runtime.onConnect.addListener((port) => {
  if (port.name !== "popup") return;
  popups.add(port);
  port.onDisconnect.addListener(() => popups.delete(port));
  port.onMessage.addListener((msg) => { if (msg?.type === "reconnect") reconnect(); });
  port.postMessage(state);
});

let publishQueued = false;

/**
 * Sends the current state to every open popup. Several changes in one turn send it once.
 */
function publish() {
  if (publishQueued || !popups.size) return;
  publishQueued = true;
  queueMicrotask(() => {
    publishQueued = false;
    for (const port of popups) {
      try { port.postMessage(state); } catch { popups.delete(port); }
    }
  });
}

// The toolbar button says whether Imp is listening (hover it, or open the popup).
function showBadge() {
  const on = state.connected;
  const status = api.i18n.getMessage(on ? "extension_status_connected" : "extension_status_not_connected");
  api.action.setTitle({ title: `${api.i18n.getMessage("extension_action_title")}: ${status}` });
  api.action.setBadgeText({ text: on ? "" : "!" });
  api.action.setBadgeBackgroundColor({ color: "#6b5a5a" });
}

function setLink(connected, connecting) {
  const changed = state.connected !== connected;
  state.connected = connected;
  state.connecting = connecting;
  if (changed) showBadge();
  publish();
}

// MARK: Connection

// The browser logs every WebSocket that can't connect as an error, even a handled one, so the
// extension's error list filled up whenever Imp was closed. A failed fetch logs nothing. A quick
// knock therefore comes first: a closed port refuses at once, while Imp's socket accepts the
// connection and waits for a WebSocket handshake, so the knock times out instead.
const KNOCK_MS = 800;
let knocking = false;

/**
 * Checks whether something is listening on Imp's port, without opening a WebSocket.
 * @returns {Promise<boolean>} True when the port answered or accepted the knock and waited.
 */
async function impIsListening() {
  const stop = new AbortController();
  const timer = setTimeout(() => stop.abort(), KNOCK_MS);
  try {
    await fetch(ADDRESS.replace(/^ws/, "http") + "/", { cache: "no-store", signal: stop.signal });
    return true;                                   // Something answered on Imp's port.
  } catch (e) {
    return e.name === "AbortError";                // The port accepted the knock and waited: Imp is there.
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Opens the WebSocket to Imp if Imp is listening and no socket is already open or opening.
 * Otherwise it schedules another attempt with retry().
 * @returns {Promise<void>}
 */
async function connect() {
  if (knocking || (socket && socket.readyState <= WebSocket.OPEN)) return;
  clearTimeout(retryTimer);
  knocking = true;
  const listening = await impIsListening();
  knocking = false;
  if (!listening) { setLink(false, false); return retry(); }
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  let s;
  try { s = new WebSocket(ADDRESS); } catch { return retry(); }
  socket = s;
  setLink(false, true);
  // Each handler checks that its socket is still the current one, because a socket closed by
  // Reconnect can report its events late.
  s.onopen = async () => {
    if (s !== socket) return;
    backoff = RETRY_FIRST;
    setLink(true, false);
    send({ type: "hello", browser: await browserReady });
    clearInterval(pingTimer);
    pingTimer = setInterval(() => send({ type: "pong" }), PING_MS);
    lastSent = "";
    reportActive();
  };
  s.onmessage = (e) => { if (s === socket) handle(e.data).catch(() => {}); };
  s.onclose = () => {
    if (s !== socket) return;
    clearInterval(pingTimer);
    socket = null;
    setLink(false, false);
    retry();
  };
  s.onerror = () => s.close();
}

/**
 * Schedules the next connect() after the current backoff, then doubles the backoff up to RETRY_LAST.
 */
function retry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, backoff);
  backoff = Math.min(backoff * 2, RETRY_LAST);
}

/**
 * Drops the current socket, if any, and dials again at once. The popup shows "connecting" right away.
 */
function reconnect() {
  backoff = RETRY_FIRST;
  const old = socket;
  socket = null;
  clearInterval(pingTimer);
  old?.close();
  setLink(false, true);
  connect();
}

/**
 * Sends one message to Imp as JSON. A message is dropped when the socket isn't open.
 * @param {object} obj The message to send.
 */
function send(obj) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(obj));
}

// MARK: The active tab

/**
 * Finds the tab in front of the last focused window.
 * @returns {Promise<chrome.tabs.Tab | undefined>} The tab, or undefined when there is none.
 */
async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, lastFocusedWindow: true });
  return tab;
}

/**
 * Tells Imp the URL and title of the active tab, unless that is what Imp was last told.
 */
async function reportActive() {
  const tab = await activeTab();
  if (!tab?.url) return;
  const key = `${tab.id}|${tab.url}|${tab.title}`;
  if (key === lastSent) return;
  lastSent = key;
  send({ type: "page", url: tab.url, title: tab.title || "" });
}

api.tabs.onActivated.addListener(() => reportActive());
api.tabs.onUpdated.addListener((id, change, tab) => {
  if (tab.active && (change.url || change.title || change.status === "complete")) reportActive();
});
api.windows.onFocusChanged.addListener((w) => { if (w !== api.windows.WINDOW_ID_NONE) reportActive(); });

// MARK: What Imp asks

/**
 * Handles one message from Imp: the Imps to show, or a request to find an element or read text.
 * @param {string} raw The message as received, a JSON string.
 */
async function handle(raw) {
  const msg = JSON.parse(raw);
  if (msg.type === "troupe") {
    state.troupe = Array.isArray(msg.imps) ? msg.imps.slice(0, 8) : [];
    publish();
    return;
  }
  const tab = await activeTab();
  if (msg.type === "locate") {
    const query = String(msg.query || "");
    const rect = tab ? await run(tab, locateInPage, [query]) : null;
    send({ type: "located", id: msg.id, rect: rect || null });
    note("find", query, !!rect, tab);
  } else if (msg.type === "text") {
    const text = tab ? await run(tab, textInPage, [Number(msg.limit) || 20000]) : "";
    send({ type: "text", id: msg.id, text: text || "" });
    note("read", "", !!text, tab);
  }
}

/**
 * Records what Imp just did, for the popup to show. It keeps the search text and the host, but never
 * what the page said.
 * @param {"find" | "read"} kind What Imp did.
 * @param {string} query The text Imp looked for, or "" for a read.
 * @param {boolean} ok Whether Imp found something or read some text.
 * @param {chrome.tabs.Tab | undefined} tab The tab the action ran in.
 */
function note(kind, query, ok, tab) {
  let host = "";
  try { host = tab?.url ? new URL(tab.url).host : ""; } catch {}
  state.activity = [{ kind, query: query.slice(0, 80), ok, host, at: Date.now() }, ...state.activity].slice(0, ACTIVITY_KEPT);
  publish();
}

/**
 * Runs a function inside a tab. No content script sits on every page, so code runs only when Imp asks.
 * @param {chrome.tabs.Tab} tab The tab to run in.
 * @param {Function} func The function to inject. It must not use anything from this file.
 * @param {unknown[]} args The arguments to pass to func.
 * @returns {Promise<unknown>} The function's result, or null when it could not run.
 */
async function run(tab, func, args) {
  try {
    const [res] = await api.scripting.executeScript({ target: { tabId: tab.id }, func, args });
    return res?.result;
  } catch {
    return null; // The browser's own pages and its extension store can't be scripted, and other failures land here too.
  }
}

/**
 * Injected into the page with run(). Returns the page's visible text.
 * @param {number} limit The most characters to return.
 * @returns {string} The trimmed text of the page body.
 */
function textInPage(limit) {
  return (document.body ? document.body.innerText : "").trim().slice(0, limit);
}

/**
 * Injected into the page with run(). Finds the best visible match for a CSS selector or a label, and
 * scrolls it into view when it is off screen.
 * @param {string} query A CSS selector, or text to match against labels such as the button text.
 * @returns {{x: number, y: number, width: number, height: number} | null} The element's box in screen
 *   points with a top-left origin, or null when nothing matches.
 */
function locateInPage(query) {
  const q = query.trim().toLowerCase();
  if (!q) return null;
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    const s = getComputedStyle(el);
    return s.visibility !== "hidden" && s.display !== "none" && Number(s.opacity) > 0;
  };
  const inView = (el) => {
    const r = el.getBoundingClientRect();
    return r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  };
  const labels = (el) => [
    el.innerText, el.value, el.getAttribute("aria-label"), el.title, el.placeholder, el.alt,
  ].filter(v => typeof v === "string").map(v => v.trim().toLowerCase().replace(/\s+/g, " ")).filter(Boolean);

  let best = null, bestScore = 0;
  const consider = (el, base) => {
    if (!visible(el)) return;
    const ls = labels(el);
    let score = 0;
    if (ls.some(l => l === q)) score = 100;
    else if (ls.some(l => l.includes(q) && l.length < q.length * 4 + 20)) score = 60;
    else if (ls.some(l => l.includes(q))) score = 30;
    if (!score) return;
    score += base + (inView(el) ? 5 : 0);
    if (score > bestScore) { best = el; bestScore = score; }
  };

  try { // A CSS selector wins when it matches something visible.
    const hit = [...document.querySelectorAll(query)].find(visible);
    if (hit) { best = hit; bestScore = Infinity; }
  } catch {}

  if (!best) {
    const strong = "button, a[href], input, select, textarea, summary, [role=button], [role=link], [role=menuitem], [role=tab], [role=checkbox], [role=switch]";
    document.querySelectorAll(strong).forEach(el => consider(el, 20));
    document.querySelectorAll("[aria-label], [title], [placeholder], label, h1, h2, h3, li, p, span, div").forEach(el => {
      if (el.children.length <= 3) consider(el, 0);
    });
  }
  if (!best) return null;

  if (!inView(best)) best.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
  const r = best.getBoundingClientRect();
  const z = innerWidth > 0 && outerWidth > 0 ? outerWidth / innerWidth : 1;
  return {
    x: screenX + r.left * z,
    y: screenY + (outerHeight - innerHeight * z) + r.top * z,
    width: r.width * z,
    height: r.height * z,
  };
}

// MARK: Start

// This code runs on every wake-up, so it needs no install or startup listeners. The alarm is
// created only when it is missing, because creating it again would push back its next ring.
api.alarms.onAlarm.addListener((alarm) => { if (alarm.name === WAKE_ALARM) connect(); });
api.alarms.get(WAKE_ALARM).then((alarm) => {
  if (!alarm) api.alarms.create(WAKE_ALARM, { periodInMinutes: 0.5 }); // Chrome allows 30 seconds at the shortest.
});
showBadge();
connect();
