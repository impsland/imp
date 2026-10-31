// The toolbar popup: the Imps that are out (alive: they watch your pointer, blink, think, sleep),
// what tab Imp knows you're on, and what it just did there.

const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);
const NS = "http://www.w3.org/2000/svg";

// While Imp isn't there (or is too old to say who's out), one red Imp stands in.
const STAND_IN = [{ name: "", hue: 0, scale: 1, mood: "idle", away: false }];
const THINKING = new Set(["thinking", "working", "listening"]);
const HAPPY = new Set(["happy", "love", "content", "giggly", "excited", "delight"]);
const LOW = new Set(["sad", "error", "scared", "bored"]);

let state = null;
let drawn = "";
let pointer = null;

// MARK: Status

function render(s) {
  state = s;
  const on = !!(s && s.connected);
  const status = $("status");
  status.classList.toggle("on", on);
  status.classList.toggle("connecting", !on && !!(s && s.connecting));
  $("status-text").textContent = on
    ? (s.browser ? `Connected · ${s.browser}` : "Connected")
    : (s && s.connecting ? "Connecting…" : "Not connected");
  $("stage").classList.toggle("asleep", !on);
  $("offline").hidden = on;
  $("get").hidden = on;
  renderTab(on ? s.page : null);
  renderActivity(on ? s.activity || [] : [], on && s.page ? hostOf(s.page.url) : "");
  renderImps(on ? (s.troupe && s.troupe.length ? s.troupe : STAND_IN) : STAND_IN, on);
}

function renderTab(page) {
  $("tab").hidden = !page;
  if (!page) return;
  let host = "";
  try { host = new URL(page.url).host; } catch {}
  $("tab-title").textContent = page.title || host || "Untitled page";
  $("tab-host").textContent = host || page.url;
  const icon = $("tab-icon");
  const usable = page.icon && /^(https?:|data:image\/)/.test(page.icon);
  icon.hidden = !usable;
  if (usable && icon.src !== page.icon) icon.src = page.icon;
  icon.onerror = () => { icon.hidden = true; $("tab-letter").hidden = false; };
  $("tab-letter").hidden = usable;
  $("tab-letter").textContent = (host.replace(/^www\./, "")[0] || "•").toUpperCase();
  // Imp can look inside ordinary web pages; the browser keeps its own pages and store to itself.
  const sight = $("tab-sight");
  const seen = /^https?:/.test(page.url) && !/(chrome\.google\.com\/webstore|chromewebstore\.google\.com|addons\.mozilla\.org)/.test(page.url);
  sight.className = `sight ${seen ? "yes" : "no"}`;
  sight.textContent = seen ? "👁" : "–";
  sight.title = seen ? "Imp can read this page and find things on it, when it needs to."
                     : "The browser keeps this page to itself: Imp only knows its address.";
}

function hostOf(url) {
  try { return new URL(url).host; } catch { return ""; }
}

/// What Imp just did. The site is named only when it isn't the tab you're on.
function renderActivity(items, here) {
  const list = $("activity-list");
  $("activity").hidden = items.length === 0;
  list.replaceChildren(...items.map((a) => {
    const li = document.createElement("li");
    if (!a.ok) li.className = "missed";
    const glyph = document.createElement("span");
    glyph.className = "glyph";
    glyph.textContent = a.kind === "find" ? (a.ok ? "🎯" : "🔍") : "📖";
    const what = document.createElement("span");
    what.className = "what";
    if (a.kind === "find") {
      what.append(a.ok ? "Found " : "Looked for ");
      const b = document.createElement("b");
      b.textContent = `“${a.query}”`;
      what.append(b);
    } else {
      what.append(a.ok ? "Read the page" : "Couldn't read the page");
    }
    if (a.host && a.host !== here) what.append(` · ${a.host}`);
    const when = document.createElement("span");
    when.className = "when";
    when.textContent = ago(a.at);
    li.append(glyph, what, when);
    return li;
  }));
}

function ago(at) {
  const s = Math.max(0, Math.round((Date.now() - at) / 1000));
  if (s < 10) return "now";
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.round(s / 60)}m`;
  return `${Math.round(s / 3600)}h`;
}

// MARK: The Imps

/// Imp's palette for a hue: a lit top, its own colour, a deep underside and darker horns.
function colors(hue) {
  const h = Math.round(((hue % 1) + 1) % 1 * 360);
  return { light: `hsl(${h} 85% 70%)`, base: `hsl(${h} 72% 54%)`, deep: `hsl(${h} 70% 36%)`, horn: `hsl(${h} 55% 26%)` };
}

function el(name, attrs, parent) {
  const node = document.createElementNS(NS, name);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  if (parent) parent.append(node);
  return node;
}

function renderImps(imps, awake) {
  const shown = imps.slice(0, 4);
  const key = JSON.stringify([awake, shown.map((i) => [i.name, Math.round(i.hue * 100), i.scale, i.mood, i.away])]);
  if (key === drawn) return;
  drawn = key;
  const many = shown.length > 2;
  $("imps").replaceChildren(...shown.map((imp, n) => drawImp(imp, n, awake, many)));
  look();
}

function drawImp(imp, n, awake, many) {
  const mood = awake ? (imp.away ? "sleepy" : imp.mood || "idle") : "sleepy";
  const size = Math.round((many ? 62 : 78) * Math.min(Math.max(imp.scale || 1, 0.75), 1.35));
  const c = colors(imp.hue || 0);
  const wrap = document.createElement("div");
  wrap.className = `imp${imp.away ? " away" : ""}`;
  wrap.title = imp.away ? `${imp.name} is on your iPhone` : imp.name;

  const svg = el("svg", { viewBox: "0 0 100 100", width: size, height: size });
  const defs = el("defs", {}, svg);
  const grad = el("radialGradient", { id: `skin${n}`, cx: "38%", cy: "30%", r: "75%" }, defs);
  el("stop", { offset: "0%", "stop-color": c.light }, grad);
  el("stop", { offset: "55%", "stop-color": c.base }, grad);
  el("stop", { offset: "100%", "stop-color": c.deep }, grad);

  el("ellipse", { cx: 50, cy: 93, rx: 30, ry: 4.5, fill: "rgba(0,0,0,0.3)" }, svg);
  // Two curled horns, then the soft mochi head.
  el("path", { d: "M31 36 C24 27 25 15 35 9 C31 17 34 25 41 30 Z", fill: c.horn }, svg);
  el("path", { d: "M69 36 C76 27 75 15 65 9 C69 17 66 25 59 30 Z", fill: c.horn }, svg);
  el("path", { d: "M8 72 C8 43 27 26 50 26 C73 26 92 43 92 72 C92 87 75 91 50 91 C25 91 8 87 8 72 Z", fill: `url(#skin${n})` }, svg);
  el("ellipse", { cx: 36, cy: 40, rx: 12, ry: 6, fill: "rgba(255,255,255,0.18)", transform: "rotate(-18 36 40)" }, svg);

  // The eyes: they move together toward the pointer (`look`).
  const eyes = el("g", { class: "eyes" }, svg);
  if (mood === "sleepy") {
    for (const x of [37, 63]) el("path", { d: `M${x - 7} 62 Q${x} 67 ${x + 7} 62`, stroke: "#fff", "stroke-width": 3.2, fill: "none", "stroke-linecap": "round" }, eyes);
    el("text", { x: 70, y: 30, class: "zz" }, svg).textContent = "z";
    el("text", { x: 78, y: 22, class: "zz two" }, svg).textContent = "z";
  } else if (HAPPY.has(mood)) {
    for (const x of [37, 63]) el("path", { d: `M${x - 7} 64 Q${x} 54 ${x + 7} 64`, stroke: "#fff", "stroke-width": 3.6, fill: "none", "stroke-linecap": "round" }, eyes);
  } else {
    const low = LOW.has(mood);
    const blink = el("g", { class: "blink" }, eyes);
    blink.style.animationDelay = `${-n * 1.7}s`;
    for (const x of [37, 63]) el("rect", { x: x - 6.5, y: low ? 58 : 53, width: 13, height: low ? 12 : 17, rx: 6.5, fill: "#fff" }, blink);
  }
  if (THINKING.has(mood)) {
    const dots = el("g", { class: "think" }, svg);
    [40, 50, 60].forEach((x) => el("circle", { cx: x, cy: 18, r: 3.2 }, dots));
  }
  wrap.append(svg);
  if (imp.name) {
    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = imp.name;
    if (imp.away) {
      // A little phone: it's out on your iPhone.
      const phone = el("svg", { viewBox: "0 0 8 12" }, tag);
      el("path", { d: "M1.6 0h4.8C7.3 0 8 .7 8 1.6v8.8c0 .9-.7 1.6-1.6 1.6H1.6C.7 12 0 11.3 0 10.4V1.6C0 .7.7 0 1.6 0zM1.4 1.6v8.8h5.2V1.6z" }, phone);
    }
    wrap.append(tag);
  }
  return wrap;
}

/// Every awake Imp looks at the pointer (or, with none in the popup, now and then somewhere else).
function look() {
  for (const wrap of document.querySelectorAll(".imp")) {
    const eyes = wrap.querySelector(".eyes");
    if (!eyes) continue;
    const box = wrap.querySelector("svg").getBoundingClientRect();
    const cx = box.left + box.width / 2, cy = box.top + box.height * 0.6;
    const target = pointer ?? wander;
    const dx = target.x - cx, dy = target.y - cy;
    const d = Math.max(1, Math.hypot(dx, dy));
    const reach = Math.min(1, d / 120) * 5;
    eyes.style.transform = `translate(${(dx / d) * reach}px, ${(dy / d) * reach * 0.7}px)`;
  }
}

let wander = { x: 165, y: 40 };
document.addEventListener("pointermove", (e) => { pointer = { x: e.clientX, y: e.clientY }; look(); });
document.addEventListener("pointerleave", () => { pointer = null; look(); });
setInterval(() => {
  if (pointer) return;
  wander = { x: 40 + Math.random() * 250, y: Math.random() * 220 };
  look();
}, 2400);

// MARK: Talking to the background

async function ask(type) {
  try { return await api.runtime.sendMessage({ type }); } catch { return null; }
}

$("reconnect").addEventListener("click", async () => {
  const button = $("reconnect");
  button.disabled = true;
  button.classList.add("spin");
  render(await ask("reconnect"));
  // Give the socket a moment, then show how it went.
  setTimeout(async () => {
    render(await ask("status"));
    button.disabled = false;
    button.classList.remove("spin");
  }, 900);
});

// Opens Imp's window, starting Imp if it isn't running (its imp:// link). The browser may ask
// first; the tab stays where it is.
$("open").addEventListener("click", async () => {
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    if (tab?.id !== undefined && /^https?:/.test(tab.url || "")) await api.tabs.update(tab.id, { url: "imp://settings" });
    else await api.tabs.create({ url: "imp://settings" });
  } catch {}
  window.close();
});

(async () => {
  render(await ask("status"));
  // Keep it fresh while the popup is open (Imp may start meanwhile, an Imp starts thinking).
  setInterval(async () => render(await ask("status")), 1000);
})();
