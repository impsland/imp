// Imp bridge: tells the Imp desktop app which page the active tab shows, and finds
// elements / reads text on that page when Imp asks. Talks only to ws://127.0.0.1:47823.
// One script for every browser: a service worker in Chrome, an event page in Firefox and Safari.

const api = globalThis.browser ?? globalThis.chrome;
const ADDRESS = "ws://127.0.0.1:47823";
// Event pages and service workers are suspended when idle, which ends their timers. An alarm
// wakes the background again, so Imp started later is found within a minute.
const WAKE_ALARM = "connect";

let socket = null;
let backoff = 1000;
let pingTimer = null;
let retryTimer = null;
let lastSent = "";
let connectedSince = null;   // when the socket to Imp opened (null: not connected)
let lastPage = null;         // the active tab: { url, title, icon }
let troupe = [];             // the Imps out right now, as Imp described them: [{ name, hue, scale, mood, away }]
let activity = [];           // what Imp just did on pages, newest first: [{ kind, query, ok, host, at }]
const ACTIVITY_KEPT = 6;
const browserName = detectBrowser();

// The browser's own name when it says (Firefox and its forks), else from the extension's
// scheme (Safari) or the Chromium brand list (Brave, Edge, Vivaldi, Opera, Chrome).
async function detectBrowser() {
  if (api.runtime.getBrowserInfo) return (await api.runtime.getBrowserInfo()).name;
  if (location.protocol === "safari-web-extension:") return "Safari";
  const brands = (navigator.userAgentData?.brands ?? []).map(b => b.brand);
  return ["Brave", "Microsoft Edge", "Vivaldi", "Opera"].find(name => brands.includes(name)) ?? "Chrome";
}

function send(obj) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(obj));
}

function connect() {
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  clearTimeout(retryTimer);
  let s;
  try { s = new WebSocket(ADDRESS); } catch { return retry(); }
  socket = s;
  // Each handler checks it still belongs to the current socket: one closed by Reconnect reports late.
  s.onopen = async () => {
    if (s !== socket) return;
    backoff = 1000;
    connectedSince = Date.now();
    showState();
    send({ type: "hello", browser: await browserName, version: 1 });
    // Socket traffic keeps a Chrome service worker alive (Chrome 116+).
    clearInterval(pingTimer);
    pingTimer = setInterval(() => send({ type: "pong" }), 20000);
    lastSent = "";
    reportActive();
  };
  s.onmessage = (e) => { if (s === socket) handle(e.data).catch(() => {}); };
  s.onclose = () => {
    if (s !== socket) return;
    clearInterval(pingTimer);
    socket = null;
    connectedSince = null;
    troupe = [];
    showState();
    retry();
  };
  s.onerror = () => s.close();
}

function retry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, backoff);
  backoff = Math.min(backoff * 2, 30000);
}

// The toolbar button says whether Imp is listening (hover it, or open the popup).
function showState() {
  const on = connectedSince !== null;
  api.action.setTitle({ title: on ? "Imp: connected" : "Imp: not connected (is Imp running?)" });
  api.action.setBadgeText({ text: on ? "" : "off" });
  api.action.setBadgeBackgroundColor({ color: "#6b5a5a" });
}

// The popup asks how things are, or to try connecting again right away.
api.runtime.onMessage.addListener((msg, sender, reply) => {
  if (sender.id !== api.runtime.id || !msg) return;
  if (msg.type === "reconnect") {
    backoff = 1000;
    const old = socket;
    clearInterval(pingTimer);
    socket = null;
    connectedSince = null;
    troupe = [];
    old?.close();
    connect();
  }
  if (msg.type === "status" || msg.type === "reconnect") {
    browserName.then(browser => reply({
      connected: connectedSince !== null,
      connecting: socket?.readyState === WebSocket.CONNECTING,
      since: connectedSince,
      browser,
      page: lastPage,
      troupe,
      activity,
      address: ADDRESS,
    }));
    return true; // answers asynchronously
  }
});

api.alarms.onAlarm.addListener((alarm) => { if (alarm.name === WAKE_ALARM) connect(); });
api.runtime.onStartup.addListener(connect);
api.runtime.onInstalled.addListener(connect);

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
  lastPage = { url: tab.url, title: tab.title || "", icon: tab.favIconUrl || "" };
  send({ type: "page", url: lastPage.url, title: lastPage.title });
}

api.tabs.onActivated.addListener(() => reportActive());
api.tabs.onUpdated.addListener((id, change, tab) => {
  if (tab.active && (change.url || change.title || change.status === "complete")) reportActive();
});
api.windows.onFocusChanged.addListener((w) => { if (w !== api.windows.WINDOW_ID_NONE) reportActive(); });

async function handle(raw) {
  const msg = JSON.parse(raw);
  if (msg.type === "troupe") {
    troupe = Array.isArray(msg.imps) ? msg.imps.slice(0, 8) : [];
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

// Remembers what Imp just did, for the popup to show (in memory only: it's gone when the browser
// puts the extension to sleep, and it never holds what the page said).
function note(kind, query, ok, tab) {
  let host = "";
  try { host = tab?.url ? new URL(tab.url).host : ""; } catch {}
  activity = [{ kind, query: query.slice(0, 80), ok, host, at: Date.now() }, ...activity].slice(0, ACTIVITY_KEPT);
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

// Registered on every start (create replaces an alarm of the same name); 30 s is the shortest
// period Chrome allows.
api.alarms.create(WAKE_ALARM, { periodInMinutes: 0.5 });
showState();
connect();
