// Imp bridge: tells the Imp desktop app which page the active tab shows, and finds
// elements / reads text on that page when Imp asks. Talks only to ws://127.0.0.1:47823.

const URL_ = "ws://127.0.0.1:47823";
const BROWSER = (() => {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands || []).map(b => b.brand);
  for (const name of ["Brave", "Microsoft Edge", "Vivaldi", "Opera"]) if (brands.includes(name)) return name;
  return "Chrome";
})();

let socket = null;
let backoff = 1000;
let pingTimer = null;
let lastSent = "";
let connectedSince = null;   // when the socket to Imp opened (null: not connected)
let lastPage = null;         // what Imp was last told: { url, title }
let retryTimer = null;

function send(obj) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(obj));
}

function connect() {
  if (socket && socket.readyState <= WebSocket.OPEN) return;
  try { socket = new WebSocket(URL_); } catch (e) { return retry(); }
  socket.onopen = () => {
    backoff = 1000;
    connectedSince = Date.now();
    showState();
    send({ type: "hello", browser: BROWSER, version: 1 });
    // Socket traffic keeps the service worker alive (Chrome 116+).
    clearInterval(pingTimer);
    pingTimer = setInterval(() => send({ type: "pong" }), 20000);
    lastSent = "";
    reportActive();
  };
  socket.onmessage = (e) => { handle(e.data).catch(() => {}); };
  socket.onclose = () => { clearInterval(pingTimer); socket = null; connectedSince = null; showState(); retry(); };
  socket.onerror = () => { try { socket.close(); } catch (_) {} };
}

function retry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, backoff);
  backoff = Math.min(backoff * 2, 30000);
}

// The toolbar button says whether Imp is listening (hover it, or open the popup).
function showState() {
  const on = connectedSince !== null;
  chrome.action.setTitle({ title: on ? "Imp: connected" : "Imp: not connected (is Imp running?)" });
  chrome.action.setBadgeText({ text: on ? "" : "off" });
  chrome.action.setBadgeBackgroundColor({ color: "#6b5a5a" });
}

// The popup asks how things are, or to try connecting again right away.
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (sender.id !== chrome.runtime.id) return;
  if (msg && msg.type === "reconnect") {
    backoff = 1000;
    clearTimeout(retryTimer);
    if (socket) { try { socket.close(); } catch (_) {} socket = null; }
    connect();
  }
  if (msg && (msg.type === "status" || msg.type === "reconnect")) {
    reply({
      connected: connectedSince !== null,
      connecting: !!socket && socket.readyState === WebSocket.CONNECTING,
      since: connectedSince,
      browser: BROWSER,
      page: lastPage,
      address: URL_,
    });
  }
});

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return tab;
}

async function reportActive() {
  const tab = await activeTab();
  if (!tab || !tab.url) return;
  const key = `${tab.id}|${tab.url}|${tab.title}`;
  if (key === lastSent) return;
  lastSent = key;
  lastPage = { url: tab.url, title: tab.title || "" };
  send({ type: "page", url: tab.url, title: tab.title || "" });
}

chrome.tabs.onActivated.addListener(() => reportActive());
chrome.tabs.onUpdated.addListener((id, change, tab) => {
  if (tab.active && (change.url || change.title || change.status === "complete")) reportActive();
});
chrome.windows.onFocusChanged.addListener((w) => { if (w !== chrome.windows.WINDOW_ID_NONE) reportActive(); });

async function handle(raw) {
  const msg = JSON.parse(raw);
  const tab = await activeTab();
  if (msg.type === "locate") {
    const rect = tab ? await run(tab, locateInPage, [String(msg.query || "")]) : null;
    send({ type: "located", id: msg.id, rect: rect || null });
  } else if (msg.type === "text") {
    const text = tab ? await run(tab, textInPage, [Number(msg.limit) || 20000]) : "";
    send({ type: "text", id: msg.id, text: text || "" });
  }
}

// On-demand injection: no content script sits on every page; code runs only when Imp asks.
async function run(tab, func, args) {
  try {
    const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func, args });
    return res && res.result;
  } catch (e) {
    return null; // chrome:// pages, the web store, etc. can't be scripted
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
  } catch (_) {}

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

showState();
connect();
