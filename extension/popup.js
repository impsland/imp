// The toolbar popup: the Imps that are out (alive: they watch your pointer, blink, think, sleep),
// what tab Imp knows you're on, and what it just did there.
//
// The background pushes its state over a port, whenever it changes. Nothing here polls, and
// nothing waits on the background: a click updates the screen at once, then the news follows.
// Every render step only touches the DOM when its value changed.

import { ImpCanvas, Clock, reducedMotion } from "./imp.js";

const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);

/** A word in the person's language (_locales). The key is the design/strings key, e.g. "extension.open". */
const t = (key, ...values) => api.i18n.getMessage(key.replace(/\./g, "_"), values.map(String));
const SVG_NS = "http://www.w3.org/2000/svg";

// While Imp isn't there (or hasn't said who's out yet), one red Imp stands in.
const STAND_IN = { name: "", hue: 0, scale: 1, mood: "idle", away: false, traits: null };
const MAX_IMPS = 4;
const MIN_TRYING = 600;    // A reconnect shows as trying for at least this long (ms), so it reads as an answer.
const GIVE_UP = 5000;      // Trying never lasts longer than this (ms).
const AGO_EVERY = 20_000;  // How often the "ago" times in the list are refreshed (ms).
const WANDER_EVERY = 2600; // How often an Imp glances somewhere when no pointer is over the popup (ms).

const still = reducedMotion();
const clock = new Clock();

let state = null;          // The last state the background sent.
let tab = null;            // The tab in front: { url, title, icon }.
let trying = 0;            // When Reconnect was pressed, in milliseconds. Zero means not trying.
let online = false;        // Which layout is showing. It stays as it was while trying, so nothing jumps.
let pointer = null;
let port = null;

// MARK: Words and help

/** Fills every word the page holds from the locale files. */
function translate() {
  document.documentElement.lang = api.i18n.getUILanguage();
  document.title = t("extension.action_title");
  for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = t(el.dataset.i18n);
  for (const el of document.querySelectorAll("[data-label]")) el.setAttribute("aria-label", t(el.dataset.label));
  for (const el of document.querySelectorAll("[data-title]")) {
    el.title = t(el.dataset.title);
    el.setAttribute("aria-label", t(el.dataset.title));
  }
  for (const el of document.querySelectorAll("[data-placeholder]")) el.placeholder = t(el.dataset.placeholder);
  for (const el of document.querySelectorAll("[data-help]")) el.setAttribute("aria-label", t("extension.help"));
  $("reconnect").title = t("extension.reconnect.help");
  $("reconnect").setAttribute("aria-label", t("extension.reconnect"));
  $("open").title = t("extension.open.help");
}

// The one help tip. A "?" button names its words in data-help. The tip opens beside the button, inside the popup.
const tip = $("tip");

/**
 * Opens the help tip beside a "?" button, or closes it when it already shows that button's words.
 * @param {HTMLButtonElement} button The button that was clicked. Its data-help names the words to show.
 */
function showTip(button) {
  const key = button.dataset.help;
  if (!key) return;
  if (tip.matches(":popover-open") && tip.dataset.for === key) return tip.hidePopover();
  tip.dataset.for = key;
  tip.textContent = t(key);
  tip.style.left = "0px";
  tip.style.top = "0px";
  tip.showPopover();
  const at = button.getBoundingClientRect();
  const room = document.documentElement.clientWidth;
  const root = getComputedStyle(document.documentElement);
  const px = (name) => parseFloat(root.getPropertyValue(name)) || 0;
  const margin = px("--space-small");
  const gap = px("--space-snug");
  const width = tip.offsetWidth;
  const left = clamp(at.left + at.width / 2 - width / 2, margin, Math.max(margin, room - width - margin));
  const below = at.bottom + gap;
  const fits = below + tip.offsetHeight <= document.documentElement.clientHeight - margin;
  tip.style.left = `${left}px`;
  tip.style.top = `${fits ? below : Math.max(margin, at.top - gap - tip.offsetHeight)}px`;
}

document.addEventListener("click", (e) => {
  const button = e.target.closest?.("button[data-help]");
  if (button) showTip(button);
});

// MARK: Small helpers

function setText(el, text) {
  if (el.textContent !== text) el.textContent = text;
}

/**
 * Gets the host name of a URL.
 * @param {string} url Any URL.
 * @returns {string} The host, such as "example.com", or "" when the URL can't be read.
 */
function hostOf(url) {
  try { return new URL(url).host; } catch { return ""; }
}

/**
 * Points an SVG <use> element at one symbol in the sprite.
 * @param {SVGUseElement} use The element to point.
 * @param {string} name The symbol id, without the "#".
 */
function icon(use, name) {
  use.setAttribute("href", `#${name}`);
}

/**
 * Keeps a number inside a range.
 * @param {number} x The number.
 * @param {number} lo The smallest allowed value.
 * @param {number} hi The largest allowed value.
 * @returns {number} x, limited to the range from lo to hi.
 */
function clamp(x, lo, hi) {
  return Math.min(Math.max(x, lo), hi);
}

// MARK: Render

/**
 * Draws every part of the popup from the latest state and tab. Each part only touches the DOM when its value changed.
 */
function render() {
  const connected = !!state?.connected;
  if (!trying) online = connected;
  $("main").hidden = !state;
  renderStatus(connected);
  $("offline").hidden = !state || online;
  renderTab(online ? tab : null);
  renderActivity(state && online ? state.activity : null);
  if (state) renderImps(state.troupe?.length ? state.troupe : [STAND_IN]);
}

function renderStatus(connected) {
  const text = trying ? t("extension.status.connecting")
    : connected ? (state.browser ? t("extension.status.connected_browser", state.browser) : t("extension.status.connected"))
    : state ? t("extension.status.not_connected") : t("extension.status.checking");
  setText($("status-text"), text);
  $("status").classList.toggle("on", connected && !trying);
  $("status").classList.toggle("connecting", !!trying || !state);
  $("stage").classList.toggle("asleep", !online);
  const button = $("reconnect");
  button.classList.toggle("spin", !!trying);
  button.setAttribute("aria-busy", trying ? "true" : "false");
}

// MARK: The tab

/**
 * Shows the tab in front, its icon, and whether Imp can look inside it.
 * @param {{url: string, title: string, icon: string} | null} page The tab to show, or null to hide the card.
 */
function renderTab(page) {
  $("tab").hidden = !page;
  if (!page) return;
  const host = hostOf(page.url);
  setText($("tab-title"), page.title || host || t("extension.tab.untitled"));
  setText($("tab-host"), host || page.url);
  const img = $("tab-icon");
  const usable = /^(https?:|data:image\/)/.test(page.icon);
  if (usable && img.getAttribute("src") !== page.icon) img.src = page.icon;
  if (!usable) img.removeAttribute("src");
  img.hidden = !usable || img.dataset.broken === page.icon;
  $("tab-fallback").toggleAttribute("hidden", !img.hidden);
  // Imp can look inside ordinary web pages. The browser keeps its own pages and its extension store to itself.
  const seen = /^https?:/.test(page.url) && !/(chrome\.google\.com\/webstore|chromewebstore\.google\.com|addons\.mozilla\.org)/.test(page.url);
  const sight = $("tab-sight");
  sight.className = `help sight ${seen ? "yes" : "no"}`;
  icon($("tab-sight-icon"), seen ? "i-eye" : "i-blind");
  sight.dataset.help = seen ? "extension.tab.sees" : "extension.tab.blind";
  sight.setAttribute("aria-label", t(sight.dataset.help));
}

$("tab-icon").addEventListener("error", (e) => {
  e.target.dataset.broken = e.target.getAttribute("src");
  e.target.hidden = true;
  $("tab-fallback").removeAttribute("hidden");
});

async function refreshTab() {
  try {
    const [t] = await api.tabs.query({ active: true, currentWindow: true });
    tab = t?.url ? { url: t.url, title: t.title || "", icon: t.favIconUrl || "" } : null;
  } catch {
    tab = null;
  }
  render();
}

api.tabs.onUpdated.addListener((id, change, t) => {
  if (t.active && (change.url || change.title || change.favIconUrl)) refreshTab();
});

// MARK: What Imp did

let activityKey = "";   // Identifies the rows on show, so an unchanged list is not drawn again.
let agoCells = [];      // The "ago" labels on show, as [{ el, at }].
let allItems = [];      // Everything the background remembers, newest first.
let fullOpen = false;   // Whether the full activity list is on show.
const PREVIEW = 5;      // How many rows the card shows before "See all".

/** The words that start a line, as the person reads them (also what a search matches). */
function rowWords(a) {
  if (a.kind === "find") return a.ok ? t("extension.activity.found") : t("extension.activity.looked_for");
  return a.ok ? t("extension.activity.read") : t("extension.activity.read_failed");
}

/** One line of the list. The site is named only when it isn't the tab you're on. */
function makeRow(a, here) {
  const li = $("row").content.firstElementChild.cloneNode(true);
  const [glyph, what, when] = li.children;
  if (!a.ok) li.className = "missed";
  icon(glyph.querySelector("use"), a.kind === "find" ? (a.ok ? "i-found" : "i-miss") : "i-read");
  if (a.kind === "find") {
    const b = document.createElement("b");
    b.textContent = `“${a.query}”`;
    what.append(`${a.ok ? t("extension.activity.found") : t("extension.activity.looked_for")} `, b);
  } else {
    what.append(a.ok ? t("extension.activity.read") : t("extension.activity.read_failed"));
  }
  if (a.host && a.host !== here) what.append(` · ${a.host}`);
  agoCells.push({ el: when, at: a.at });
  return li;
}

/**
 * Shows the recent activity card. The rows are drawn again only when the list changed.
 * @param {Array<{kind: string, query: string, ok: boolean, host: string, at: number}> | null} items The
 *   background's activity, newest first, or null to hide the card while Imp is offline.
 */
function renderActivity(items) {
  $("activity").hidden = !items;
  if (!items) return;
  allItems = items;
  $("activity-empty").hidden = items.length > 0;
  $("activity-all").hidden = items.length <= PREVIEW;
  setText($("activity-all-text"), t("extension.activity.see_all", items.length));
  const here = tab ? hostOf(tab.url) : "";
  const key = `${here}|${items.map((a) => `${a.at}${a.ok}`).join()}`;
  if (key === activityKey) return;
  activityKey = key;
  if (fullOpen) renderFull();
  $("activity-list").replaceChildren(...items.slice(0, PREVIEW).map((a) => makeRow(a, here)));
  agoCells = agoCells.filter((c) => c.el.isConnected);
  tickAgo();
}

// MARK: The full activity list. It opens in place of the popup's other cards, with search and a scrolling list.

/**
 * Draws the full activity list, filtered by the search box.
 */
function renderFull() {
  const q = $("full-search").value.trim().toLowerCase();
  const here = tab ? hostOf(tab.url) : "";
  const text = (a) => `${a.kind === "find" ? a.query : ""} ${a.host || ""} ${rowWords(a)}`.toLowerCase();
  const hits = q ? allItems.filter((a) => text(a).includes(q)) : allItems;
  $("full-list").replaceChildren(...hits.map((a) => makeRow(a, here)));
  agoCells = agoCells.filter((c) => c.el.isConnected);
  $("full-empty").hidden = hits.length > 0;
  setText($("full-empty"), allItems.length ? t("extension.activity.no_match") : t("extension.activity.empty"));
  setText($("full-count"), q ? t("extension.activity.count_some", hits.length, allItems.length) : t("extension.activity.count_all", allItems.length));
  tickAgo();
}

/**
 * Shows or hides the full activity list. Closing it returns to the popup's normal cards.
 * @param {boolean} open True to show the full list.
 */
function openFull(open) {
  fullOpen = open;
  document.body.classList.toggle("full", open);
  $("full").hidden = !open;
  activityKey = "";
  if (open) {
    $("full-search").value = "";
    renderFull();
    $("full-search").focus();
  } else {
    render();
    $("activity-all").focus();
  }
}

$("activity-all").addEventListener("click", () => openFull(true));
$("full-back").addEventListener("click", () => openFull(false));
$("full-search").addEventListener("input", renderFull);
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && fullOpen && !tip.matches(":popover-open")) {
    e.preventDefault();
    openFull(false);
  }
});

/**
 * Words for how long ago something happened, such as "now", "5 seconds ago" or "2 hours ago".
 * @param {number} at The time, in milliseconds since the epoch.
 * @returns {string} The translated phrase.
 */
function ago(at) {
  const s = Math.max(0, Math.round((Date.now() - at) / 1000));
  if (s < 10) return t("extension.ago.now");
  if (s < 60) return t("extension.ago.seconds", s);
  if (s < 3600) return t("extension.ago.minutes", Math.round(s / 60));
  return t("extension.ago.hours", Math.round(s / 3600));
}

function tickAgo() {
  for (const c of agoCells) setText(c.el, ago(c.at));
}

// MARK: The Imps

const cells = [];   // One per Imp on the stage: { root, canvas, tag, name, phone, fig, look, size, mood, rect, wander }.

/**
 * Builds the card for one Imp on the stage and adds it to the page.
 * @param {number} n The Imp's position on the stage. It also sets the animation phase, so Imps don't move in step.
 * @returns {object} The cell: its elements, its drawing (fig), and the values last drawn.
 */
function makeCell(n) {
  const root = document.createElement("div");
  root.className = "imp";
  const canvas = document.createElement("canvas");
  canvas.setAttribute("role", "img");
  const tag = document.createElement("span");
  tag.className = "tag";
  const name = document.createElement("span");
  name.className = "name";
  const phone = document.createElementNS(SVG_NS, "svg");
  phone.classList.add("phone");
  phone.setAttribute("aria-hidden", "true");
  phone.append(document.createElementNS(SVG_NS, "use"));
  icon(phone.firstChild, "i-phone");
  tag.append(name, phone);
  root.append(canvas, tag);
  $("imps").append(root);
  const fig = new ImpCanvas(canvas, { live: !still, phase: n * 1.7 });
  if (!still) clock.add(fig);
  return { root, canvas, tag, name, phone, fig, look: "", size: 0, mood: "", rect: null, wander: null };
}

/**
 * Takes one Imp off the stage and stops its drawing.
 * @param {object} cell A cell made by makeCell().
 */
function removeCell(cell) {
  clock.remove(cell.fig);
  cell.root.remove();
}

/**
 * Shows the Imps in the list, up to MAX_IMPS. Cards are added, removed or updated to match.
 * @param {Array<object>} list The Imps to show, as the background sent them.
 */
function renderImps(list) {
  const shown = list.slice(0, MAX_IMPS);
  const many = shown.length > 2;
  let changed = false;
  while (cells.length > shown.length) { removeCell(cells.pop()); changed = true; }
  shown.forEach((imp, n) => {
    if (!cells[n]) { cells[n] = makeCell(n); changed = true; }
    changed = updateCell(cells[n], imp, many) || changed;
  });
  if (changed) for (const cell of cells) cell.rect = null;   // The layout moved, so measure again when needed.
}

/** Brings one Imp up to date. True if its size changed. Only what differs is touched. */
function updateCell(cell, imp, many) {
  const away = !!imp.away;
  // The status is the Imp's real one, wherever it is. Away only says where.
  const status = ["working", "idle", "asleep"].includes(imp.status) ? imp.status : "idle";
  const mood = !online || status === "asleep" ? "sleepy" : status === "working" && !["thinking", "working"].includes(imp.mood) ? "working" : imp.mood || "idle";
  if (mood !== cell.mood) { cell.mood = mood; cell.fig.setMood(mood); }

  const look = JSON.stringify([imp.hue, imp.traits]);
  if (look !== cell.look) { cell.look = look; cell.fig.setImp(imp); }

  const size = Math.round((many ? 70 : 88) * clamp(Number(imp.scale) || 1, 0.75, 1.05));
  const resized = size !== cell.size;
  if (resized) { cell.size = size; cell.fig.resize(size); }

  const name = String(imp.name || "");
  const device = String(imp.device || "") || t("extension.imp.device_default");
  const label = !name ? ""
    : status === "working" ? (away ? t("extension.imp.working_away", name, device) : t("extension.imp.working", name))
    : away ? t("extension.imp.away", name, device)
    : status === "asleep" ? t("extension.imp.asleep", name)
    : name;
  const named = label || t("extension.imp.fallback");
  if (cell.canvas.getAttribute("aria-label") !== named) cell.canvas.setAttribute("aria-label", named);
  cell.root.title = label;
  cell.root.classList.toggle("away", away);
  setText(cell.name, name);
  cell.tag.hidden = !name;
  cell.phone.style.display = away ? "" : "none";
  return resized;
}

// MARK: Looking at the pointer

/** Where the pointer is from an Imp, as -1…1 on both axes (or where it glances while there is none). */
function aim(cell) {
  if (!pointer) return cell.fig.setGaze(cell.wander);
  cell.rect ??= cell.canvas.getBoundingClientRect();
  const dx = pointer.x - (cell.rect.left + cell.rect.width / 2);
  const dy = pointer.y - (cell.rect.top + cell.rect.height / 2);
  const d = Math.max(1, Math.hypot(dx, dy));
  const k = Math.min(1, d / 220);
  cell.fig.setGaze([(dx / d) * k, (dy / d) * k]);
}

function aimAll() {
  for (const cell of cells) aim(cell);
}

let wanderTimer = 0;

/**
 * Pauses the animation and the idle glances while the popup is hidden, and resumes them when it shows again.
 */
function rest() {
  clock.pause(document.hidden);
  clearInterval(wanderTimer);
  if (document.hidden || still) return;
  wanderTimer = setInterval(() => {
    if (pointer) return;
    for (const cell of cells) cell.wander = [(Math.random() - 0.5) * 1.6, (Math.random() - 0.5) * 0.7];
    aimAll();
  }, WANDER_EVERY);
}

if (!still) { // with reduced motion the Imps hold still poses and don't follow the pointer
  document.addEventListener("pointermove", (e) => { pointer = { x: e.clientX, y: e.clientY }; aimAll(); }, { passive: true });
  document.documentElement.addEventListener("pointerleave", () => { pointer = null; aimAll(); });
}
document.addEventListener("visibilitychange", rest);
// Refreshes the "ago" labels. The timer keeps running, but the tick does nothing while the popup is hidden.
setInterval(() => { if (!document.hidden) tickAgo(); }, AGO_EVERY);
rest();

// MARK: The background

/**
 * Opens the port to the background. It is opened again when the background goes to sleep.
 */
function connect() {
  try {
    port = api.runtime.connect({ name: "popup" });
  } catch {
    return; // The extension was reloaded under this popup, so there is nothing to talk to.
  }
  port.onMessage.addListener((s) => {
    state = s;
    settle();
    render();
  });
  // Browsers put the background to sleep and close the port. Connecting again wakes it.
  port.onDisconnect.addListener(() => { port = null; setTimeout(connect, 300); });
}

/** Ends "trying" once the attempt is over and has been on show long enough to be seen. */
function settle() {
  if (!trying) return;
  const waited = performance.now() - trying;
  if (waited >= GIVE_UP || (waited >= MIN_TRYING && !state?.connecting)) trying = 0;
}

const settleAndRender = () => { settle(); render(); };

// Pressing Reconnect changes the screen right now. The background is only told.
$("reconnect").addEventListener("click", () => {
  if (trying) return;
  trying = performance.now();
  if (!port) connect();
  port?.postMessage({ type: "reconnect" });
  setTimeout(settleAndRender, MIN_TRYING);
  setTimeout(settleAndRender, GIVE_UP);
  render();
});

// Opens Imp's window through its imp:// link, which also starts Imp when it isn't running. The
// browser may ask first. When the tab in front shows a web page, this navigates that same tab to
// the link, so the page is replaced. Otherwise it opens a new tab.
$("open").addEventListener("click", async () => {
  try {
    const [t] = await api.tabs.query({ active: true, currentWindow: true });
    if (t?.id !== undefined && /^https?:/.test(t.url || "")) await api.tabs.update(t.id, { url: "imp://settings" });
    else await api.tabs.create({ url: "imp://settings" });
  } catch {}
  window.close();
});

translate();
render();
connect();
refreshTab();
