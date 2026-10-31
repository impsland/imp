// Imp bridge: tells the Imp desktop app which page the active tab shows, and finds
// elements / reads text on that page when Imp asks. Talks only to ws://127.0.0.1:47823.
// One script for every browser: a service worker in Chrome, an event page in Firefox and Safari.
// Either may be put to sleep when idle and woken by an event, so nothing is kept anywhere but in
// these variables: what Imp tells us again on every connection, and a short list of what it just
// did (gone with the sleep, on purpose).

const api = globalThis.browser ?? globalThis.chrome;
const ADDRESS = "ws://127.0.0.1:47823";
// Sleeping ends timers. An alarm wakes the background again, so Imp started later is found within a minute.
const WAKE_ALARM = "connect";
const PING_MS = 20_000;     // socket traffic keeps a Chrome service worker alive (Chrome 116+)
const RETRY_FIRST = 1_000;
const RETRY_LAST = 30_000;
const ACTIVITY_KEPT = 6;

// Everything the popup draws. Pushed to it whenever it changes.
const state = {
  connected: false,   // the socket to Imp is open
  connecting: false,  // an attempt is in flight
  browser: "",
  troupe: [],         // the Imps out, as Imp described them: [{ name, hue, scale, traits, mood, away }]
  activity: [],       // what Imp just did on pages, newest first: [{ kind, query, ok, host, at }]
};
const popups = new Set();   // open popup ports
const browserReady = detectBrowser().then((name) => { state.browser = name; publish(); return name; });

let socket = null;
let backoff = RETRY_FIRST;
let pingTimer = null;
let retryTimer = null;
let lastSent = "";

// The browser's own name when it says (Firefox and its forks), else from the extension's
// scheme (Safari) or the Chromium brand list (Brave, Edge, Vivaldi, Opera, Chrome).
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

// Tells every open popup, once per burst of changes.
let publishQueued = false;
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
  api.action.setTitle({ title: on ? "Imp: connected" : "Imp: not connected (is Imp running?)" });
  api.action.setBadgeText({ text: on ? "" : "off" });
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

function connect() {
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  clearTimeout(retryTimer);
  let s;
  try { s = new WebSocket(ADDRESS); } catch { return retry(); }
  socket = s;
  setLink(false, true);
  // Each handler checks it still belongs to the current socket: one closed by Reconnect reports late.
  s.onopen = async () => {
    if (s !== socket) return;
    backoff = RETRY_FIRST;
    setLink(true, false);
    send({ type: "hello", browser: await browserReady, version: 1 });
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

function retry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, backoff);
  backoff = Math.min(backoff * 2, RETRY_LAST);
}

// Drops the socket (if any) and dials again at once; the popup hears "connecting" right away.
function reconnect() {
  backoff = RETRY_FIRST;
  const old = socket;
  socket = null;
  clearInterval(pingTimer);
  old?.close();
  connect();
}

function send(obj) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(obj));
}

// MARK: The active tab

async function activeTab() {
  const [tab] = await api.tabs.query({ active: true, lastFocusedWindow: true });
  return tab;
}

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

// Remembers what Imp just did, for the popup to show (it never holds what the page said).
function note(kind, query, ok, tab) {
  let host = "";
  try { host = tab?.url ? new URL(tab.url).host : ""; } catch {}
  state.activity = [{ kind, query: query.slice(0, 80), ok, host, at: Date.now() }, ...state.activity].slice(0, ACTIVITY_KEPT);
  publish();
}

// On-demand injection: no content script sits on every page; code runs only when Imp asks.
async function run(tab, func, args) {
  try {
    const [res] = await api.scripting.executeScript({ target: { tabId: tab.id }, func, args });
    return res?.result;
  } catch {
    return null; // the browser's own pages and its extension store can't be scripted
  }
}

// Injected: self-contained, runs in the page.
function textInPage(limit) {
  return (document.body ? document.body.innerText : "").trim().slice(0, limit);
}

// Injected: self-contained, runs in the page. Returns screen points, top-left origin.
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

  try { // a CSS selector wins if it matches something visible
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

// This runs on every wake-up, so no install or startup listeners are needed. The alarm is only
// created when missing: creating it again would push its next ring back each time we wake.
api.alarms.onAlarm.addListener((alarm) => { if (alarm.name === WAKE_ALARM) connect(); });
api.alarms.get(WAKE_ALARM).then((alarm) => {
  if (!alarm) api.alarms.create(WAKE_ALARM, { periodInMinutes: 0.5 }); // 30 s is the shortest Chrome allows
});
showBadge();
connect();
