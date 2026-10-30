// The Den's web gallery. Plain modules, no build step. Everything the API or a kit says reaches
// the page through textContent and attributes, never as markup.
import {
  drawImp, normalizeImp, normalizeAnimation, hueName, traitsSummary, reducedMotion, MOODS, DEFAULT_IMP,
} from './imp.js';

const KINDS = [
  ['', 'All'], ['imp', 'Imps'], ['animation', 'Animations'], ['trigger', 'Triggers'], ['tool', 'Tools'], ['kit', 'Kits'],
];
const KIND_NAMES = { imp: 'Imp', animation: 'Animation', trigger: 'Trigger', tool: 'Tool', kit: 'Kit' };
const PAGE_SIZE = 24;
const HANDLE_RE = /^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$/;
const SLUG_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

const main = document.getElementById('main');
const live = document.getElementById('live');
const totals = document.getElementById('totals');

// ---------------------------------------------------------------- small helpers

function h(tag, props, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === 'class') e.className = v;
    else if (k === 'text') e.textContent = v;
    else if (k.startsWith('on')) e.addEventListener(k.slice(2), v);
    else if (v === true) e.setAttribute(k, '');
    else e.setAttribute(k, String(v));
  }
  const add = (kid) => {
    if (kid === null || kid === undefined || kid === false) return;
    if (Array.isArray(kid)) kid.forEach(add);
    else e.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  };
  kids.forEach(add);
  return e;
}

const SVGNS = 'http://www.w3.org/2000/svg';
function svgEl(tag, attrs, ...kids) {
  const e = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) e.setAttribute(k, String(v));
  kids.forEach((kid) => e.append(kid));
  return e;
}

const number = new Intl.NumberFormat();
const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' });

function formatDate(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return h('span', { text: 'unknown date' });
  return h('time', { datetime: d.toISOString(), text: dateFormat.format(d) });
}

function plural(n, one, many) {
  return `${number.format(n)} ${n === 1 ? one : many}`;
}

function seconds(x) {
  return `${Math.round(x * 100) / 100} s`;
}

function announce(text) {
  live.textContent = '';
  setTimeout(() => { live.textContent = text; }, 30);
}

const enc = encodeURIComponent;
const itemPath = (handle, slug) => `/i/${enc(handle)}/${enc(slug)}`;
const accountPath = (handle) => `/a/${enc(handle)}`;

function link(href, props, ...kids) {
  return h('a', { href, 'data-route': '', ...props }, ...kids);
}

// ---------------------------------------------------------------- API

class ApiError extends Error {
  constructor({ status = 0, title, detail = '', retryAfter = 0 }) {
    super(title);
    this.status = status;
    this.title = title;
    this.detail = detail;
    this.retryAfter = retryAfter;
  }
}

async function api(path, { method = 'GET', body } = {}) {
  const init = { method, headers: { Accept: 'application/json, application/problem+json' } };
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  let res;
  try {
    res = await fetch(path, init);
  } catch {
    throw new ApiError({ title: 'The Den could not be reached', detail: 'Check your connection and try again.' });
  }
  const text = await res.text();
  let data = null;
  if (text) {
    try { data = JSON.parse(text); } catch { data = null; }
  }
  if (!res.ok) {
    const retryAfter = Number.parseInt(res.headers.get('Retry-After') || '', 10) || 0;
    const problem = data && typeof data === 'object' ? data : {};
    let title = typeof problem.title === 'string' && problem.title ? problem.title : `Something went wrong (${res.status})`;
    let detail = typeof problem.detail === 'string' ? problem.detail : '';
    if (res.status === 429) {
      title = typeof problem.title === 'string' && problem.title ? problem.title : 'Too many requests';
      if (!detail) detail = 'Please slow down a little.';
      if (retryAfter && !/try again/i.test(detail)) detail = `${detail} Try again in ${plural(retryAfter, 'second', 'seconds')}.`;
    }
    throw new ApiError({ status: res.status, title, detail, retryAfter });
  }
  return data;
}

function asApiError(e) {
  return e instanceof ApiError ? e : new ApiError({ title: 'Something went wrong', detail: String(e && e.message ? e.message : e) });
}

function errorBox(e, retry) {
  const err = asApiError(e);
  return h('div', { class: 'notice error', role: 'alert' },
    h('strong', { text: err.title }),
    err.detail ? h('p', { text: err.detail }) : null,
    retry ? h('button', { type: 'button', class: 'btn small', onclick: retry, text: 'Try again' }) : null);
}

// ---------------------------------------------------------------- view lifecycle

let routeToken = 0;
let cleanups = [];

function onCleanup(fn) {
  cleanups.push(fn);
}

function resetView() {
  const old = cleanups;
  cleanups = [];
  old.forEach((fn) => { try { fn(); } catch { /* a view that is already gone */ } });
}

function show(...nodes) {
  main.replaceChildren(...nodes.filter(Boolean));
}

function loading(text) {
  return h('p', { class: 'loading', role: 'status' }, h('span', { class: 'spinner', 'aria-hidden': 'true' }), text);
}

function notFound(what) {
  show(h('section', { class: 'panel narrow' },
    h('h1', { text: 'Nothing here' }),
    h('p', { class: 'muted', text: what }),
    h('p', null, link('/', { class: 'btn', text: 'Back to the gallery' }))));
  document.title = 'Not found - The Den';
  announce('Not found');
}

// ---------------------------------------------------------------- stats

let statsCache = null;

async function loadStats() {
  if (statsCache && Date.now() - statsCache.at < 30000) return statsCache.data;
  const data = await api('/v1/stats');
  statsCache = { at: Date.now(), data };
  return data;
}

function statsLine(s) {
  return `${plural(s.items || 0, 'item', 'items')} from ${plural(s.accounts || 0, 'account', 'accounts')}, added to Imp ${plural(s.installs || 0, 'time', 'times')}.`;
}

async function fillFooter() {
  try {
    totals.textContent = statsLine(await loadStats());
  } catch {
    totals.textContent = '';
  }
}

// ---------------------------------------------------------------- icons and avatars

function kindIcon(kind) {
  const art = {
    imp: [svgEl('path', { d: 'M24 44C20 30 22 22 28 18C31 28 36 34 42 38Z', fill: 'currentColor', opacity: '.7' }),
      svgEl('path', { d: 'M76 44C80 30 78 22 72 18C69 28 64 34 58 38Z', fill: 'currentColor', opacity: '.7' }),
      svgEl('path', { d: 'M50 30C70 30 82 44 82 60C82 72 70 80 50 80C30 80 18 72 18 60C18 44 30 30 50 30Z', fill: 'currentColor' })],
    animation: [svgEl('path', { d: 'M50 12C53 36 58 44 82 48C58 52 53 60 50 84C47 60 42 52 18 48C42 44 47 36 50 12Z', fill: 'currentColor' }),
      svgEl('circle', { cx: 80, cy: 20, r: 5, fill: 'currentColor' }), svgEl('circle', { cx: 20, cy: 24, r: 4, fill: 'currentColor' })],
    trigger: [svgEl('path', { d: 'M56 14L28 54H48L43 86L72 44H52Z', fill: 'currentColor' })],
    tool: [svgEl('circle', { cx: 50, cy: 50, r: 26, fill: 'currentColor' }),
      svgEl('circle', { cx: 50, cy: 50, r: 11, fill: 'var(--glyph-bg)' }),
      ...Array.from({ length: 8 }, (_, i) => svgEl('rect', { x: 45, y: 12, width: 10, height: 16, rx: 3, fill: 'currentColor', transform: `rotate(${i * 45} 50 50)` }))],
    kit: [svgEl('path', { d: 'M50 14L84 30V70L50 86L16 70V30Z', fill: 'currentColor' }),
      svgEl('path', { d: 'M16 30L50 46L84 30M50 46V86', fill: 'none', stroke: 'var(--glyph-bg)', 'stroke-width': 5, 'stroke-linejoin': 'round' })],
  };
  return svgEl('svg', { class: 'glyph', viewBox: '0 0 100 100', 'aria-hidden': 'true', focusable: 'false' },
    svgEl('rect', { x: 6, y: 6, width: 88, height: 88, rx: 26, fill: 'var(--glyph-bg)' }),
    svgEl('g', { transform: 'translate(14 14) scale(.72)' }, ...(art[kind] || art.kit)));
}

const kitCache = new Map();
function fetchKit(handle, slug) {
  const key = `${handle}/${slug}`;
  if (!kitCache.has(key)) {
    const p = api(`/v1/items/${enc(handle)}/${enc(slug)}/kit.json`);
    p.catch(() => kitCache.delete(key));
    kitCache.set(key, p);
  }
  return kitCache.get(key);
}

// Imp cards draw their Imp from the kit, a few at a time and only once they scroll into view.
let avatarSlots = 0;
const avatarQueue = [];
function pumpAvatars() {
  while (avatarSlots < 3 && avatarQueue.length) {
    const job = avatarQueue.shift();
    avatarSlots += 1;
    job().finally(() => { avatarSlots -= 1; pumpAvatars(); });
  }
}

let avatarObserver = null;
function observeAvatar(holder, item) {
  if (!('IntersectionObserver' in window)) return;
  if (!avatarObserver) {
    avatarObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        avatarObserver.unobserve(entry.target);
        const job = entry.target.avatarJob;
        if (job) { avatarQueue.push(job); pumpAvatars(); }
      }
    }, { rootMargin: '200px' });
  }
  holder.avatarJob = async () => {
    try {
      const kit = await fetchKit(item.handle, item.slug);
      const first = kit && Array.isArray(kit.imps) ? kit.imps[0] : null;
      if (!first || !holder.isConnected) return;
      const svg = svgEl('svg', { class: 'imp-art' });
      const figure = drawImp(svg, first);
      holder.replaceChildren(svg);
      holder.classList.add('has-imp');
      figure.destroy();
    } catch { /* the glyph stays */ }
  };
  avatarObserver.observe(holder);
}

// ---------------------------------------------------------------- badges and cards

function warningBadge(long) {
  return h('span', { class: 'badge warn', title: 'Runs programs on your Mac: review it in Imp before adding.' },
    h('span', { 'aria-hidden': 'true', text: '⚠ ' }),
    long ? 'Runs programs on your Mac: review it in Imp before adding' : 'Runs programs');
}

function kindBadge(kind) {
  return h('span', { class: `badge kind kind-${KIND_NAMES[kind] ? kind : 'kit'}`, text: KIND_NAMES[kind] || 'Kit' });
}

function tagLinks(tags) {
  if (!Array.isArray(tags) || !tags.length) return null;
  return h('ul', { class: 'tags', 'aria-label': 'Tags' }, tags.slice(0, 12).map((t) => h('li', null,
    link(`/?tag=${enc(String(t))}`, { class: 'tag', text: `#${String(t)}` }))));
}

function itemCard(item) {
  const holder = h('div', { class: 'card-art' }, kindIcon(item.kind));
  if (item.kind === 'imp') observeAvatar(holder, item);
  const name = String(item.name || item.slug);
  return h('li', { class: 'card' },
    holder,
    h('div', { class: 'card-body' },
      h('h3', { class: 'card-title' }, link(itemPath(item.handle, item.slug), { class: 'card-link', text: name })),
      h('p', { class: 'badges' }, kindBadge(item.kind), item.runs_programs ? warningBadge(false) : null),
      item.summary ? h('p', { class: 'card-summary', text: item.summary }) : null,
      tagLinks(item.tags),
      h('p', { class: 'card-meta muted' },
        link(accountPath(item.handle), { text: `@${item.handle}` }),
        h('span', { 'aria-hidden': 'true', text: ' · ' }),
        h('span', { text: plural(item.installs || 0, 'install', 'installs') }),
        h('span', { 'aria-hidden': 'true', text: ' · ' }),
        h('span', { text: `rev ${item.revision || 1}` }),
        h('span', { 'aria-hidden': 'true', text: ' · ' }),
        formatDate(item.updated_at))));
}

// ---------------------------------------------------------------- gallery

function readFilters() {
  const q = new URLSearchParams(location.search);
  const kind = q.get('kind') || '';
  return {
    kind: KINDS.some(([k]) => k === kind) ? kind : '',
    tag: (q.get('tag') || '').slice(0, 40),
    q: (q.get('q') || '').slice(0, 100),
    sort: q.get('sort') === 'popular' ? 'popular' : 'new',
  };
}

function filterUrl(f) {
  const q = new URLSearchParams();
  if (f.kind) q.set('kind', f.kind);
  if (f.tag) q.set('tag', f.tag);
  if (f.q) q.set('q', f.q);
  if (f.sort !== 'new') q.set('sort', f.sort);
  const s = q.toString();
  return s ? `/?${s}` : '/';
}

async function renderGallery(token) {
  document.title = 'The Den - Imp';
  const filters = readFilters();
  let cursor = null;
  let listToken = 0;

  const statsEl = h('p', { class: 'stats-line', text: '' });
  const heroSvg = svgEl('svg', { class: 'hero-imp', 'aria-hidden': 'true' });
  const heroFigure = drawImp(heroSvg, DEFAULT_IMP, { live: true, follow: true });
  heroSvg.removeAttribute('role');
  heroSvg.removeAttribute('aria-label');
  onCleanup(() => heroFigure.destroy());
  const hero = h('section', { class: 'hero', 'aria-labelledby': 'hero-title' },
    h('div', { class: 'hero-text' },
      h('p', { class: 'eyebrow', text: 'The Den' }),
      h('h1', { id: 'hero-title', text: 'What Imps make, shared' }),
      h('p', { class: 'lede' }, 'Whole Imps, animations, triggers and tools from people and from agents. Press ',
        h('b', { text: 'Add to Imp' }), ' and your Mac shows you everything before it adds a thing.'),
      statsEl),
    h('div', { class: 'hero-art', 'aria-hidden': 'true' }, h('div', { class: 'arch' }), heroSvg, h('div', { class: 'pedestal' })));

  const search = h('input', { type: 'search', id: 'q', name: 'q', value: filters.q, maxlength: 100, autocomplete: 'off', placeholder: 'Search the Den' });
  const sort = h('select', { id: 'sort', name: 'sort' },
    h('option', { value: 'new', text: 'Newest' }), h('option', { value: 'popular', text: 'Most added' }));
  sort.value = filters.sort;
  const kindButtons = KINDS.map(([value, label]) => h('button', {
    type: 'button', class: 'chip', 'data-kind': value, 'aria-pressed': String(filters.kind === value), text: label,
    onclick: () => { filters.kind = value; apply(); },
  }));
  const tagBar = h('p', { class: 'active-tag' });
  const form = h('form', { class: 'filters', role: 'search', 'aria-label': 'Search the gallery', onsubmit: (e) => { e.preventDefault(); filters.q = search.value.trim(); apply(); } },
    h('div', { class: 'field grow' }, h('label', { for: 'q', text: 'Search' }), search),
    h('div', { class: 'field' }, h('label', { for: 'sort', text: 'Sort' }), sort),
    h('div', { class: 'kinds', role: 'group', 'aria-label': 'Kind' }, kindButtons));

  const grid = h('ul', { class: 'grid', 'aria-label': 'Items' });
  const status = h('p', { class: 'status muted', role: 'status', 'aria-live': 'polite' });
  const errorHost = h('div');
  const more = h('button', { type: 'button', class: 'btn', hidden: true, text: 'Load more', onclick: () => loadPage(true) });
  const results = h('section', { 'aria-label': 'Results' }, tagBar, grid, errorHost, status, h('p', { class: 'more' }, more));

  show(hero, form, results);

  let debounce = 0;
  search.addEventListener('input', () => {
    clearTimeout(debounce);
    debounce = setTimeout(() => { filters.q = search.value.trim(); apply(true); }, 350);
  });
  sort.addEventListener('change', () => { filters.sort = sort.value; apply(); });
  onCleanup(() => clearTimeout(debounce));

  function syncControls() {
    kindButtons.forEach((b) => b.setAttribute('aria-pressed', String(b.getAttribute('data-kind') === filters.kind)));
    tagBar.replaceChildren();
    tagBar.hidden = !filters.tag;
    if (filters.tag) {
      tagBar.append('Tag: ', h('strong', { text: `#${filters.tag}` }), ' ',
        h('button', { type: 'button', class: 'btn small ghost', text: 'Clear tag', onclick: () => { filters.tag = ''; apply(); } }));
    }
  }

  function apply(quiet) {
    history.replaceState(null, '', filterUrl(filters));
    syncControls();
    loadPage(false, quiet);
  }

  async function loadPage(append, quiet) {
    const mine = ++listToken;
    if (!append) {
      cursor = null;
      if (!quiet) grid.replaceChildren();
    }
    errorHost.replaceChildren();
    more.hidden = true;
    more.disabled = true;
    status.textContent = 'Loading…';
    const q = new URLSearchParams({ limit: String(PAGE_SIZE), sort: filters.sort });
    if (filters.kind) q.set('kind', filters.kind);
    if (filters.tag) q.set('tag', filters.tag);
    if (filters.q) q.set('q', filters.q);
    if (append && cursor) q.set('cursor', cursor);
    try {
      const page = await api(`/v1/items?${q}`);
      if (mine !== listToken || token !== routeToken) return;
      const items = Array.isArray(page && page.items) ? page.items : [];
      if (!append) grid.replaceChildren();
      items.forEach((item) => grid.append(itemCard(item)));
      cursor = page && typeof page.next_cursor === 'string' ? page.next_cursor : null;
      more.hidden = !cursor;
      more.disabled = false;
      const count = grid.children.length;
      status.textContent = count ? `Showing ${plural(count, 'item', 'items')}${cursor ? '' : '. That is everything.'}` : 'Nothing matches yet. Try fewer words or another kind.';
    } catch (e) {
      if (mine !== listToken || token !== routeToken) return;
      status.textContent = '';
      errorHost.replaceChildren(errorBox(e, () => loadPage(append)));
      more.disabled = false;
    }
  }

  syncControls();
  loadPage(false);
  loadStats().then((s) => {
    if (token !== routeToken) return;
    statsEl.textContent = `${statsLine(s)} Counts update about once a minute.`;
    const byKind = s.by_kind || {};
    kindButtons.forEach((b) => {
      const k = b.getAttribute('data-kind');
      if (k && typeof byKind[k] === 'number') b.title = plural(byKind[k], 'item', 'items');
    });
  }).catch(() => {});
  announce('Gallery');
}

// ---------------------------------------------------------------- account

async function renderAccount(handle, token) {
  if (!HANDLE_RE.test(handle)) return notFound('That is not a handle.');
  show(loading('Loading…'));
  document.title = `@${handle} - The Den`;
  let account;
  try {
    account = await api(`/v1/accounts/${enc(handle)}`);
  } catch (e) {
    if (token !== routeToken) return;
    if (asApiError(e).status === 404) return notFound(`Nobody called @${handle} has shared anything here.`);
    return show(h('section', { class: 'panel narrow' }, errorBox(e, () => renderAccount(handle, token))));
  }
  if (token !== routeToken) return;
  const items = Array.isArray(account.items) ? account.items : [];
  const grid = h('ul', { class: 'grid', 'aria-label': `Items by @${handle}` }, items.map((i) => itemCard(i)));
  show(
    h('nav', { class: 'crumbs', 'aria-label': 'Breadcrumb' }, link('/', { text: 'Gallery' }), ' / ', h('span', { text: `@${handle}` })),
    h('header', { class: 'page-head' },
      h('p', { class: 'eyebrow', text: 'Account' }),
      h('h1', { text: `@${account.handle || handle}` }),
      h('p', { class: 'muted' }, 'Here since ', formatDate(account.created_at), ' · ', plural(items.length, 'item', 'items'))),
    items.length ? grid : h('p', { class: 'muted', text: 'Nothing shared yet.' }));
  announce(`@${handle}, ${plural(items.length, 'item', 'items')}`);
}

// ---------------------------------------------------------------- beats

function describeLook(b) {
  return b.look ? `look ${b.look.map((n) => Math.round(n * 100) / 100).join(', ')}` : '';
}

function beatParts(b) {
  const parts = [];
  if (b.mood) parts.push(b.mood);
  if (b.look) parts.push(describeLook(b));
  if (b.glyph) parts.push(`${b.glyph} glyph`);
  if (b.hop) parts.push('hop');
  if (b.move) parts.push(`${b.move}${b.times > 1 ? ` ×${b.times}` : ''}${b.reverse ? ' reversed' : ''}`);
  if (b.tilt) parts.push(`tilt ${b.tilt}°`);
  if (b.stretch) parts.push(`stretch ${b.stretch > 0 ? '+' : ''}${b.stretch}`);
  return parts;
}

function beatShort(b) {
  if (b.move) return b.move;
  if (b.mood) return b.mood;
  if (b.glyph) return b.glyph;
  if (b.hop) return 'hop';
  if (b.look) return 'look';
  return 'hold';
}

// ---------------------------------------------------------------- the stage (an Imp that plays animations)

function buildStage(imps) {
  const list = imps.length ? imps : [{ name: 'Imp', imp: normalizeImp(DEFAULT_IMP), isDefault: true }];
  const svg = svgEl('svg', { class: 'stage-imp' });
  const figure = drawImp(svg, list[0].imp, { live: true, follow: true });
  onCleanup(() => figure.destroy());
  const caption = h('p', { class: 'caption', role: 'status', 'aria-live': 'polite' });
  let index = 0;
  let current = null;

  const impSelect = list.length > 1
    ? h('select', { id: 'stage-imp', onchange: () => select(Number(impSelect.value)) },
      list.map((entry, i) => h('option', { value: i, text: entry.name })))
    : null;
  const moodSelect = h('select', { id: 'stage-mood', onchange: () => {
    stopCurrent();
    figure.setMood(moodSelect.value);
    caption.textContent = moodSelect.value === 'idle' ? '' : `Feeling ${moodSelect.value}.`;
  } }, MOODS.map((m) => h('option', { value: m, text: m })));

  function select(i) {
    stopCurrent();
    index = i;
    figure.setImp(list[i].imp);
    figure.setMood(moodSelect.value);
    if (impSelect) impSelect.value = String(i);
    caption.textContent = '';
  }

  function stopCurrent() {
    if (current) current.ctl.stop();
  }

  const stage = {
    figure, list, caption,
    get index() { return index; },
    select,
    stopCurrent,
    get current() { return current; },
    play(entry, hooks) {
      stopCurrent();
      const ctl = figure.play(entry.anim, {
        onBeat: (i) => {
          hooks.onBeat(i);
          caption.textContent = i >= 0 ? `${entry.title}: beat ${i + 1} of ${entry.anim.beats.length}` : '';
        },
        onEnd: () => {
          if (current && current.entry === entry) current = null;
          hooks.onEnd();
        },
      });
      if (!ctl.skipped) current = { entry, ctl };
      return ctl;
    },
    pose(beat, label) {
      stopCurrent();
      figure.pose(beat);
      caption.textContent = label;
    },
    el: h('section', { class: 'stage', 'aria-labelledby': 'stage-title' },
      h('h2', { id: 'stage-title', text: 'Stage' }),
      h('div', { class: 'stage-arch' }, h('div', { class: 'arch' }), svg, h('div', { class: 'pedestal' })),
      h('div', { class: 'stage-controls' },
        impSelect ? h('div', { class: 'field' }, h('label', { for: 'stage-imp', text: 'Imp' }), impSelect) : null,
        h('div', { class: 'field' }, h('label', { for: 'stage-mood', text: 'Mood' }), moodSelect)),
      caption,
      list[0].isDefault ? h('p', { class: 'muted small', text: 'This kit has no Imp of its own, so a plain red one plays its animations.' }) : null,
      reducedMotion() ? h('p', { class: 'muted small', text: 'Your device asks for less motion, so nothing moves here. Pick a beat in a timeline to see its pose.' }) : null),
  };
  moodSelect.value = 'idle';
  return stage;
}

function animationEntry(raw, ownerIndex, ownerName, i) {
  const anim = normalizeAnimation(raw);
  const title = (anim && anim.name) || (anim && anim.replaces) || (raw && typeof raw.name === 'string' && raw.name.trim()) || `Animation ${i + 1}`;
  return { raw, anim, owner: ownerIndex, ownerName, title: String(title) };
}

function animationCard(entry, stage) {
  const { anim } = entry;
  const id = `anim-${Math.random().toString(36).slice(2, 8)}`;
  if (!anim) {
    return h('li', { class: 'anim' }, h('h3', { text: entry.title }), h('p', { class: 'muted', text: 'This animation has no beats Imp can read.' }));
  }
  const motionOff = reducedMotion();
  const playBtn = motionOff ? null : h('button', { type: 'button', class: 'btn small', 'aria-pressed': 'false' }, h('span', { 'aria-hidden': 'true', text: '▶ ' }), 'Play');
  const segs = anim.beats.map((b, i) => {
    const btn = h('button', {
      type: 'button', class: 'beat', 'aria-label': `Beat ${i + 1}, ${seconds(b.duration)}${beatParts(b).length ? `: ${beatParts(b).join(', ')}` : ''}. Show this pose.`,
      title: beatParts(b).join(', ') || 'holds still',
    }, h('span', { class: 'beat-n', text: String(i + 1) }), h('span', { class: 'beat-name', text: beatShort(b) }));
    const li = h('li', { class: 'seg' }, btn);
    li.style.flexGrow = String(Math.max(b.duration, 0.12));
    li.style.flexBasis = '0';
    btn.addEventListener('click', () => {
      marks(i, true);
      stage.pose(b, `${entry.title}, beat ${i + 1}: ${beatParts(b).join(', ') || 'holds still'}`);
    });
    return li;
  });
  function marks(index, selected) {
    segs.forEach((li, i) => {
      li.classList.toggle('now', !selected && i === index);
      li.classList.toggle('picked', selected && i === index);
      const b = li.firstChild;
      if (!selected && i === index) b.setAttribute('aria-current', 'step'); else b.removeAttribute('aria-current');
    });
  }
  function reset() {
    if (!playBtn) return;
    playBtn.setAttribute('aria-pressed', 'false');
    playBtn.replaceChildren(h('span', { 'aria-hidden': 'true', text: '▶ ' }), 'Play');
    marks(-1, false);
  }
  if (playBtn) {
    playBtn.addEventListener('click', () => {
      if (stage.current && stage.current.entry === entry) { stage.stopCurrent(); return; }
      if (entry.owner !== null && entry.owner !== stage.index) stage.select(entry.owner);
      stage.play(entry, {
        onBeat: (i) => marks(i, false),
        onEnd: reset,
      });
      if (stage.current && stage.current.entry === entry) {
        playBtn.setAttribute('aria-pressed', 'true');
        playBtn.replaceChildren(h('span', { 'aria-hidden': 'true', text: '■ ' }), 'Stop');
      }
    });
  }
  const rows = anim.beats.map((b, i) => {
    const start = anim.beats.slice(0, i).reduce((s, x) => s + x.duration, 0);
    return h('tr', null,
      h('th', { scope: 'row', text: String(i + 1) }),
      h('td', { text: `${seconds(start)} to ${seconds(start + b.duration)}` }),
      h('td', { text: b.mood || '' }),
      h('td', { text: b.look ? b.look.map((n) => Math.round(n * 100) / 100).join(', ') : '' }),
      h('td', { text: [b.hop ? 'hop' : '', b.move ? `${b.move}${b.times > 1 ? ` ×${b.times}` : ''}${b.reverse ? ' reversed' : ''}` : ''].filter(Boolean).join(', ') }),
      h('td', { text: [b.tilt ? `tilt ${b.tilt}°` : '', b.stretch ? `stretch ${b.stretch}` : ''].filter(Boolean).join(', ') }),
      h('td', { text: b.glyph || '' }));
  });
  return h('li', { class: 'anim', 'aria-labelledby': id },
    h('div', { class: 'anim-head' },
      h('div', null,
        h('h3', { id, text: entry.title }),
        h('p', { class: 'muted small' },
          `${plural(anim.beats.length, 'beat', 'beats')}, ${seconds(anim.duration)}`,
          entry.ownerName ? ` · belongs to ${entry.ownerName}` : '',
          anim.replaces ? ` · replaces the built-in “${anim.replaces}”` : '',
          anim.enabled ? '' : ' · shipped switched off')),
      playBtn),
    anim.about ? h('p', { class: 'anim-about', text: anim.about }) : null,
    anim.starts.length ? h('p', { class: 'small' }, 'Starts on: ', anim.starts.map((s) => h('span', { class: 'chip static', text: s }))) : null,
    h('ol', { class: 'timeline', 'aria-label': `Beats of ${entry.title}` }, segs),
    h('details', { class: 'beat-details' },
      h('summary', { text: 'Beat details' }),
      h('div', { class: 'table-wrap' },
        h('table', null,
          h('caption', { class: 'sr-only', text: `Beats of ${entry.title}` }),
          h('thead', null, h('tr', null, ['Beat', 'Time', 'Mood', 'Look', 'Move', 'Pose', 'Glyph'].map((t) => h('th', { scope: 'col', text: t })))),
          h('tbody', null, rows)))));
}

// ---------------------------------------------------------------- kit sections

function impCard(entry) {
  const raw = entry.raw;
  const svg = svgEl('svg', { class: 'imp-art' });
  const figure = drawImp(svg, entry.imp);
  onCleanup(() => figure.destroy());
  const own = Array.isArray(raw.animations) ? raw.animations.length : 0;
  const trig = Array.isArray(raw.triggers) ? raw.triggers.length : 0;
  const personality = typeof raw.personality === 'string' ? raw.personality.trim() : '';
  const chips = [
    own ? plural(own, 'animation', 'animations') : '',
    trig ? plural(trig, 'trigger', 'triggers') : '',
    raw.shell === true ? 'Can use the shell' : '',
  ].filter(Boolean);
  return h('li', { class: 'imp-card' },
    h('div', { class: 'imp-art-wrap' }, svg),
    h('div', null,
      h('h3', { text: entry.imp.name }),
      h('p', { class: 'muted small', text: `${hueName(entry.imp.hue)}, ${traitsSummary(entry.imp.traits).toLowerCase()}` }),
      personality ? h('p', { class: 'persona', text: personality.length > 280 ? `${personality.slice(0, 280)}…` : personality }) : null,
      chips.length ? h('p', null, chips.map((c) => h('span', { class: 'chip static', text: c }))) : null));
}

function describeWhen(w) {
  if (!w || typeof w !== 'object') return 'Unknown';
  const text = typeof w.text === 'string' ? w.text : '';
  const num = typeof w.number === 'number' ? w.number : null;
  switch (w.kind) {
    case 'keys': return `You press ${w.keys || 'a key combination'}`;
    case 'time': return `At ${text}`;
    case 'hours': return `During ${text}`;
    case 'wake': return 'The Mac wakes up';
    case 'start': return 'Imp starts';
    case 'app': return `You switch to ${text}`;
    case 'website': return `You visit ${text}`;
    case 'charger': return w.flag === false ? 'The charger is unplugged' : 'The charger is plugged in';
    case 'offline': return w.flag === false ? 'The Mac is online' : 'The Mac is offline';
    default: {
      const bits = [typeof w.kind === 'string' ? w.kind : 'unknown', text, num !== null ? String(num) : ''].filter(Boolean);
      return bits.join(' ');
    }
  }
}

function triggerCard(raw, i, ownerName) {
  const t = raw && typeof raw === 'object' ? raw : {};
  const name = typeof t.name === 'string' && t.name.trim() ? t.name.trim() : `Trigger ${i + 1}`;
  const conditions = Array.isArray(t.only_if) ? t.only_if : [];
  return h('li', { class: 'trigger' },
    h('h3', { text: name }),
    ownerName ? h('p', { class: 'muted small', text: `For ${ownerName}` }) : null,
    h('dl', { class: 'facts' },
      h('div', null, h('dt', { text: 'When' }), h('dd', { text: describeWhen(t.when) })),
      conditions.length ? h('div', null, h('dt', { text: 'Only if' }), h('dd', { text: conditions.map(describeWhen).join('; ') })) : null,
      h('div', null, h('dt', { text: 'Does' }), h('dd', { text: typeof t.do === 'string' ? t.do : 'ask' })),
      t.with_clipboard === true ? h('div', null, h('dt', { text: 'Reads' }), h('dd', { text: 'what you copied' })) : null),
    typeof t.prompt === 'string' && t.prompt ? h('blockquote', { class: 'prompt', text: t.prompt }) : null);
}

function toolCard(name, cfg) {
  const c = cfg && typeof cfg === 'object' ? cfg : {};
  const runs = typeof c.command === 'string' && c.command !== '';
  const args = Array.isArray(c.args) ? c.args.filter((a) => typeof a === 'string') : [];
  const envNames = c.env && typeof c.env === 'object' ? Object.keys(c.env) : [];
  const headerNames = c.headers && typeof c.headers === 'object' ? Object.keys(c.headers) : [];
  return h('li', { class: runs ? 'tool runs' : 'tool' },
    h('h3', { text: name }),
    h('p', { class: 'badges' }, runs ? warningBadge(true) : h('span', { class: 'badge', text: 'Talks to a server' })),
    h('dl', { class: 'facts' },
      runs ? h('div', null, h('dt', { text: 'Command' }), h('dd', null, h('code', { text: [c.command, ...args].join(' ') }))) : null,
      !runs && typeof c.url === 'string' ? h('div', null, h('dt', { text: 'Address' }), h('dd', null, h('code', { text: c.url }))) : null,
      envNames.length ? h('div', null, h('dt', { text: 'Environment' }), h('dd', { text: `${envNames.join(', ')} (you add your own values)` })) : null,
      headerNames.length ? h('div', null, h('dt', { text: 'Headers' }), h('dd', { text: `${headerNames.join(', ')} (you add your own values)` })) : null));
}

function section(title, id, intro, content) {
  return h('section', { class: 'block', 'aria-labelledby': id },
    h('h2', { id, text: title }),
    intro ? h('p', { class: 'muted', text: intro }) : null,
    content);
}

function renderKit(kit, host) {
  const parts = [];
  const rawImps = Array.isArray(kit.imps) ? kit.imps.filter((i) => i && typeof i === 'object') : [];
  const imps = rawImps.slice(0, 20).map((raw) => ({ raw, name: normalizeImp(raw).name, imp: normalizeImp(raw) }));

  const animEntries = [];
  (Array.isArray(kit.animations) ? kit.animations : []).slice(0, 50).forEach((raw, i) => animEntries.push(animationEntry(raw, null, '', i)));
  imps.forEach((entry, k) => {
    (Array.isArray(entry.raw.animations) ? entry.raw.animations : []).slice(0, 50)
      .forEach((raw, i) => animEntries.push(animationEntry(raw, k, entry.name, i)));
  });

  const triggers = [];
  (Array.isArray(kit.triggers) ? kit.triggers : []).slice(0, 50).forEach((t, i) => triggers.push(triggerCard(t, i, '')));
  imps.forEach((entry) => {
    (Array.isArray(entry.raw.triggers) ? entry.raw.triggers : []).slice(0, 50).forEach((t, i) => triggers.push(triggerCard(t, i, entry.name)));
  });

  const servers = kit.mcpServers && typeof kit.mcpServers === 'object' && !Array.isArray(kit.mcpServers) ? Object.entries(kit.mcpServers).slice(0, 20) : [];

  const stage = imps.length || animEntries.length ? buildStage(imps) : null;
  if (imps.length) parts.push(section(imps.length === 1 ? 'The Imp' : 'The Imps', 'imps-title', '', h('ul', { class: 'imps' }, imps.map(impCard))));
  if (animEntries.length) {
    parts.push(section('Animations', 'anims-title',
      'Each animation is a list of beats. Play one on the stage, or pick a beat to see its pose.',
      h('ul', { class: 'anims' }, animEntries.map((entry) => animationCard(entry, stage)))));
  }
  if (triggers.length) parts.push(section('Triggers', 'triggers-title', 'What starts an Imp, and what it is asked to do.', h('ul', { class: 'cards-list' }, triggers)));
  if (servers.length) {
    parts.push(section('Tools', 'tools-title', 'Tools an Imp borrows from MCP servers.', h('ul', { class: 'cards-list' }, servers.map(([name, cfg]) => toolCard(name, cfg)))));
  }
  if (!parts.length) parts.push(h('p', { class: 'muted', text: 'This kit has nothing Imp can show here.' }));

  const body = h('div', { class: stage ? 'kit-body with-stage' : 'kit-body' }, stage ? stage.el : null, h('div', { class: 'kit-main' }, parts));
  host.replaceChildren(body);
}

// ---------------------------------------------------------------- item page

function absoluteKitUrl(item) {
  const fallback = `${location.origin}/v1/items/${enc(item.handle)}/${enc(item.slug)}/kit.json`;
  try {
    const u = new URL(item.kit_url || fallback, location.origin);
    return u.protocol === 'https:' || u.protocol === 'http:' ? u.href : fallback;
  } catch {
    return fallback;
  }
}

function reportForm(item) {
  const text = h('textarea', { id: 'report-reason', rows: 4, maxlength: 500, required: true, 'aria-describedby': 'report-count' });
  const count = h('span', { id: 'report-count', class: 'muted small', text: '0 / 500' });
  const result = h('div', { role: 'status', 'aria-live': 'polite' });
  const send = h('button', { type: 'submit', class: 'btn small', text: 'Send report' });
  text.addEventListener('input', () => { count.textContent = `${text.value.length} / 500`; });
  const form = h('form', { class: 'report', hidden: true, onsubmit: async (e) => {
    e.preventDefault();
    const reason = text.value.trim();
    if (!reason) { result.replaceChildren(h('p', { class: 'notice error', text: 'Say what is wrong first.' })); return; }
    send.disabled = true;
    result.replaceChildren(loading('Sending…'));
    try {
      await api(`/v1/items/${enc(item.handle)}/${enc(item.slug)}/reports`, { method: 'POST', body: { reason: reason.slice(0, 500) } });
      text.value = '';
      count.textContent = '0 / 500';
      result.replaceChildren(h('p', { class: 'notice ok', text: 'Thanks. Your report was sent.' }));
    } catch (err) {
      result.replaceChildren(errorBox(err));
    } finally {
      send.disabled = false;
    }
  } },
    h('div', { class: 'field' }, h('label', { for: 'report-reason', text: 'What is wrong with this item?' }), text, count),
    h('p', null, send), result);
  return form;
}

async function renderItem(handle, slug, token) {
  if (!HANDLE_RE.test(handle) || !SLUG_RE.test(slug)) return notFound('That is not an item address.');
  show(loading('Loading…'));
  document.title = `${slug} - The Den`;
  let item;
  try {
    item = await api(`/v1/items/${enc(handle)}/${enc(slug)}`);
  } catch (e) {
    if (token !== routeToken) return;
    if (asApiError(e).status === 404) return notFound('Nobody has shared that, or it was taken down.');
    return show(h('section', { class: 'panel narrow' }, errorBox(e, () => renderItem(handle, slug, token))));
  }
  if (token !== routeToken) return;

  const name = String(item.name || item.slug);
  document.title = `${name} by @${item.handle} - The Den`;
  const kitUrl = absoluteKitUrl(item);
  const addHref = `imp://add?url=${enc(kitUrl)}`;
  const addBtn = h('a', { class: 'btn primary', href: addHref, rel: 'noopener' }, 'Add to Imp');
  addBtn.addEventListener('click', () => {
    fetch(`/v1/items/${enc(item.handle)}/${enc(item.slug)}/installs`, { method: 'POST', keepalive: true }).catch(() => {});
  });
  const form = reportForm(item);
  const reportBtn = h('button', { type: 'button', class: 'btn ghost', 'aria-expanded': 'false', text: 'Report', onclick: () => {
    form.hidden = !form.hidden;
    reportBtn.setAttribute('aria-expanded', String(!form.hidden));
    if (!form.hidden) form.querySelector('textarea').focus();
  } });
  const copyBtn = navigator.clipboard && navigator.clipboard.writeText
    ? h('button', { type: 'button', class: 'btn ghost', text: 'Copy kit address', onclick: async () => {
      try { await navigator.clipboard.writeText(kitUrl); copyBtn.textContent = 'Copied'; } catch { copyBtn.textContent = 'Could not copy'; }
      setTimeout(() => { copyBtn.textContent = 'Copy kit address'; }, 2000);
    } })
    : null;
  const kitHost = h('div', { class: 'kit-host' }, loading('Loading the kit…'));

  show(
    h('nav', { class: 'crumbs', 'aria-label': 'Breadcrumb' },
      link('/', { text: 'Gallery' }), ' / ', link(accountPath(item.handle), { text: `@${item.handle}` }), ' / ', h('span', { text: name })),
    h('header', { class: 'item-head' },
      h('div', null,
        h('p', { class: 'badges' }, kindBadge(item.kind)),
        h('h1', { text: name }),
        item.summary ? h('p', { class: 'lede', text: item.summary }) : null,
        h('p', { class: 'meta muted' },
          'by ', link(accountPath(item.handle), { text: `@${item.handle}` }),
          h('span', { 'aria-hidden': 'true', text: ' · ' }), `revision ${item.revision || 1}`,
          h('span', { 'aria-hidden': 'true', text: ' · ' }), 'updated ', formatDate(item.updated_at),
          h('span', { 'aria-hidden': 'true', text: ' · ' }), plural(item.installs || 0, 'install', 'installs')),
        tagLinks(item.tags),
        item.about ? h('p', { class: 'about', text: item.about }) : null)),
    item.runs_programs
      ? h('div', { class: 'notice warn', role: 'note' },
        h('strong', null, h('span', { 'aria-hidden': 'true', text: '⚠ ' }), 'Runs programs on your Mac: review it in Imp before adding.'),
        h('p', { text: 'This kit starts programs on your computer. Imp lists every command before it adds anything. Read them, and only add it if you trust who made it.' }))
      : null,
    h('div', { class: 'actions' }, addBtn,
      h('a', { class: 'btn ghost', href: kitUrl, download: `${item.slug}.json`, text: 'Download kit.json' }), copyBtn, reportBtn),
    h('p', { class: 'muted small', text: 'Add to Imp opens the Imp app on your Mac. Install counts update about once a minute.' }),
    form,
    h('details', { class: 'tech' },
      h('summary', { text: 'Technical details' }),
      h('dl', { class: 'facts' },
        h('div', null, h('dt', { text: 'Kit address' }), h('dd', null, h('code', { text: kitUrl }))),
        item.sha256 ? h('div', null, h('dt', { text: 'SHA-256' }), h('dd', null, h('code', { text: String(item.sha256) }))) : null,
        typeof item.size === 'number' ? h('div', null, h('dt', { text: 'Size' }), h('dd', { text: `${number.format(item.size)} bytes` })) : null,
        item.created_at ? h('div', null, h('dt', { text: 'First shared' }), h('dd', null, formatDate(item.created_at))) : null)),
    kitHost);
  announce(`${name} by @${item.handle}`);

  async function loadKit() {
    kitHost.replaceChildren(loading('Loading the kit…'));
    try {
      const kit = await fetchKit(item.handle, item.slug);
      if (token !== routeToken) return;
      renderKit(kit && typeof kit === 'object' ? kit : {}, kitHost);
    } catch (e) {
      if (token !== routeToken) return;
      kitHost.replaceChildren(errorBox(e, loadKit));
    }
  }
  loadKit();
}

// ---------------------------------------------------------------- routing

function parseRoute(path) {
  const clean = path.replace(/\/+$/, '') || '/';
  let m = /^\/i\/([^/]+)\/([^/]+)$/.exec(clean);
  if (m) return { name: 'item', handle: safeDecode(m[1]), slug: safeDecode(m[2]) };
  m = /^\/a\/([^/]+)$/.exec(clean);
  if (m) return { name: 'account', handle: safeDecode(m[1]) };
  return { name: 'gallery' };
}

function safeDecode(s) {
  try { return decodeURIComponent(s); } catch { return ''; }
}

function render() {
  const token = ++routeToken;
  resetView();
  const route = parseRoute(location.pathname);
  const run = route.name === 'item' ? renderItem(route.handle, route.slug, token)
    : route.name === 'account' ? renderAccount(route.handle, token)
      : renderGallery(token);
  Promise.resolve(run).catch((e) => {
    if (token === routeToken) show(h('section', { class: 'panel narrow' }, errorBox(e)));
  });
  fillFooter();
}

function navigate(href) {
  const url = new URL(href, location.origin);
  if (url.origin !== location.origin) { location.href = url.href; return; }
  history.pushState(null, '', url.pathname + url.search);
  render();
  window.scrollTo(0, 0);
  main.focus({ preventScroll: true });
}

document.addEventListener('click', (e) => {
  if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
  const a = e.target instanceof Element ? e.target.closest('a[data-route]') : null;
  if (!a || a.target === '_blank') return;
  e.preventDefault();
  navigate(a.getAttribute('href'));
});

window.addEventListener('popstate', render);
render();
