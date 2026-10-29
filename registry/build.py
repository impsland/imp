#!/usr/bin/env python3
"""Builds the Imp Kits gallery from registry/kits/*.json into a static site (Python 3 standard library only).

    python3 registry/build.py --out registry/site [--base-url https://impsland.github.io/imp]
    python3 -m http.server -d registry/site

The site has no external requests: no CDNs, fonts, analytics or trackers. Kits are validated for
the registry's own rules here (metadata, no secrets); the real kit parser is `Imp --check-kit`.
"""
import argparse
import html
import json
import math
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEFAULT_BASE = "https://impsland.github.io/imp"
RELEASES_DMG = "https://github.com/impsland/imp/releases/latest/download/Imp.dmg"
BREW = "brew install --cask impsland/tap/imp"
REPO = "https://github.com/impsland/imp"
FORMAT_DOCS = REPO + "#share-setups-as-kits"
REGISTRY_DOCS = REPO + "/tree/main/registry"

# The oldest Imp that reads each kit format version. The one place this is written down.
MIN_IMP_FOR_FORMAT = {1: "1.6", 2: "1.7", 3: "1.9"}

TOOL_GROUPS = [("body", "Body language"), ("senses", "Senses"), ("setup", "Sets itself up"),
               ("troupe", "Talks to the troupe"), ("computer", "Computer control")]
GROUP_DEFAULT_ON = {"body": True, "senses": True, "setup": True, "troupe": True, "computer": False}
TYPES = [("imps", "Imps"), ("animations", "Animations"), ("triggers", "Triggers"), ("tools", "Tools")]
MOODS = {"idle", "listening", "thinking", "happy", "love", "sad", "error", "sleepy", "annoyed", "surprised", "dizzy",
         "mean", "working", "content", "giggly", "scared", "curious", "shy", "excited", "bored"}
GLYPHS = {"notes", "question", "exclaim", "idea", "sweat", "heart", "sparkles"}
MAX_ANIMATIONS = 50
MAX_BEATS, MIN_BEAT, MAX_BEAT, MAX_TOTAL = 24, 0.05, 6.0, 20.0
TRAIT_RANGES = {"lids": (0, 0.6), "slant": (-1, 1), "eyes": (-0.4, 0.4), "squint": (-1, 1), "horns": (-30, 30),
                "blush": (0, 1), "tilt": (-12, 12), "tempo": (0.6, 1.6)}
SLUG = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
MAX_BYTES = 512 * 1024
E = html.escape


# ---------------------------------------------------------------- kits

class Kit:
    def __init__(self, path):
        self.slug = path.stem
        self.raw = path.read_text(encoding="utf-8")
        self.data = json.loads(self.raw)
        d = self.data
        reg = d.get("registry") or {}
        self.name = (d.get("name") or "").strip()
        self.about = (d.get("about") or "").strip()
        self.author = (reg.get("author") or "").strip()
        self.tags = [str(t).strip().lower() for t in reg.get("tags") or []]
        self.summary = (reg.get("summary") or "").strip()
        self.version = int(d.get("imp") or 1)
        self.imps = d.get("imps") or []
        self.triggers = d.get("triggers") or []          # the loose ones
        self.servers = d.get("mcpServers") or {}
        used = {n for i in self.imps for n in (i.get("mcpServers") or [])}
        self.loose_servers = {k: v for k, v in self.servers.items() if k not in used}
        self.animations = [a for a in d.get("animations") or [] if isinstance(a, dict)] if isinstance(d.get("animations"), list) else []
        self.imp_animations = [a for i in self.imps if isinstance(i, dict) and isinstance(i.get("animations"), list)
                               for a in i["animations"] if isinstance(a, dict)]
        self.all_animations = self.animations + self.imp_animations
        self.types = []
        if self.imps:
            self.types.append("imps")
        if self.animations:
            self.types.append("animations")
        if self.triggers:
            self.types.append("triggers")
        if self.loose_servers:
            self.types.append("tools")
        self.primary = self.types[0] if self.types else "tools"
        self.all_triggers = list(self.triggers) + [t for i in self.imps for t in i.get("triggers") or []]
        self.runs_commands = any("command" in s for s in self.servers.values())
        self.needs_keys = any((s.get("env") or s.get("headers")) for s in self.servers.values())
        self.controls_mac = any(tool_on(i, "computer") for i in self.imps)
        self.min_imp = MIN_IMP_FOR_FORMAT.get(self.version, str(self.version))

    def problems(self):
        out = []
        if not SLUG.match(self.slug):
            out.append("file name must be lowercase letters, digits and dashes")
        if len(self.raw.encode()) > MAX_BYTES:
            out.append("larger than 512 KB")
        for field, value in (("name", self.name), ("about", self.about), ("registry.author", self.author),
                             ("registry.summary", self.summary)):
            if not value:
                out.append(f"missing {field}")
        if not self.tags:
            out.append("registry.tags needs at least one tag")
        if "\n" in self.summary or len(self.summary) > 120:
            out.append("registry.summary must be one line, at most 120 characters")
        for s_name, s in self.servers.items():
            for key, value in {**(s.get("env") or {}), **(s.get("headers") or {})}.items():
                if value != "":
                    out.append(f"tool {s_name}: value of {key} must be empty (no secrets in a kit)")
            if "?" in (s.get("url") or ""):
                out.append(f"tool {s_name}: no query string in a url (keys hide there)")
        out += self.animation_problems()
        if "chats" in self.raw:
            for i in self.imps:
                if i.get("chats"):
                    out.append(f"Imp {i.get('name')}: chats don't belong in a registry kit")
        return out

    def animation_problems(self):
        out = []
        groups = [("", self.data.get("animations"))] + [
            (f"Imp {i.get('name')}: ", i.get("animations")) for i in self.imps if isinstance(i, dict)]
        total = 0
        for where, anims in groups:
            if anims is None:
                continue
            if not isinstance(anims, list):
                out.append(f"{where}animations must be a list")
                continue
            total += len(anims)
            for n, a in enumerate(anims):
                out += [f"{where}animation {a.get('name') or n + 1}: {p}" if isinstance(a, dict) else f"{where}animation {n + 1}: not an object"
                        for p in (animation_problems(a) if isinstance(a, dict) else [""])]
        if total > MAX_ANIMATIONS:
            out.append(f"{total} animations; at most {MAX_ANIMATIONS} per kit")
        for i in self.imps:
            tr = i.get("traits") if isinstance(i, dict) else None
            if tr is None:
                continue
            if not isinstance(tr, dict):
                out.append(f"Imp {i.get('name')}: traits must be an object")
                continue
            for key, v in tr.items():
                if key in TRAIT_RANGES:
                    lo, hi = TRAIT_RANGES[key]
                    if not is_num(v) or not lo <= v <= hi:
                        out.append(f"Imp {i.get('name')}: trait {key} must be a number from {lo} to {hi}")
        return out

    # URLs
    def page_url(self, base):
        return f"{base}/k/{self.slug}/"

    def json_url(self, base):
        return f"{base}/kits/{self.slug}.json"

    def add_url(self, base):
        return f"imp://add?url={self.json_url(base)}"


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def animation_problems(a):
    out = []
    name = a.get("name")
    if not isinstance(name, str) or not name.strip():
        out.append("missing name")
    elif len(name.strip()) > 40:
        out.append("name longer than 40 characters")
    beats = a.get("beats")
    if not isinstance(beats, list) or not 1 <= len(beats) <= MAX_BEATS:
        out.append(f"needs 1 to {MAX_BEATS} beats")
        return out
    total = 0.0
    for n, b in enumerate(beats, 1):
        if not isinstance(b, dict):
            out.append(f"beat {n}: not an object")
            continue
        d = b.get("duration")
        if not is_num(d) or not MIN_BEAT <= d <= MAX_BEAT:
            out.append(f"beat {n}: duration must be a number from {MIN_BEAT} to {MAX_BEAT} seconds")
        else:
            total += d
        if "mood" in b and b["mood"] not in MOODS:
            out.append(f"beat {n}: unknown mood {b['mood']!r}")
        if "glyph" in b and b["glyph"] not in GLYPHS:
            out.append(f"beat {n}: unknown glyph {b['glyph']!r}")
        look = b.get("look")
        if look is not None and not (isinstance(look, list) and len(look) == 2 and all(is_num(x) and -1 <= x <= 1 for x in look)):
            out.append(f"beat {n}: look must be [x, y] with each from -1 to 1")
        for key, lo, hi in (("tilt", -30, 30), ("stretch", -0.3, 0.3)):
            if key in b and (not is_num(b[key]) or not lo <= b[key] <= hi):
                out.append(f"beat {n}: {key} must be a number from {lo} to {hi}")
        if "hop" in b and not isinstance(b["hop"], bool):
            out.append(f"beat {n}: hop must be true or false")
    if total > MAX_TOTAL:
        out.append(f"{total:.1f} s long; at most {MAX_TOTAL:g} s")
    return out


def tool_on(imp, group):
    return (imp.get("tools") or {}).get(group, GROUP_DEFAULT_ON[group])


def load_kits():
    kits, errors = [], []
    for path in sorted((ROOT / "kits").glob("*.json")):
        try:
            kit = Kit(path)
        except Exception as e:  # noqa: BLE001
            errors.append(f"{path.name}: {e}")
            continue
        errors += [f"{path.name}: {p}" for p in kit.problems()]
        kits.append(kit)
    order = {"imps": 0, "animations": 1, "triggers": 2, "tools": 3}
    kits.sort(key=lambda k: (order[k.primary], k.name.lower()))
    return kits, errors


# ---------------------------------------------------------------- the Imp, drawn as in the app

def hsv(h, s, v):
    h6 = (h - math.floor(h)) * 6
    i = int(math.floor(h6))
    f = h6 - i
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    r, g, b = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i % 6]
    return r, g, b


def hexc(rgb):
    return "#%02x%02x%02x" % tuple(round(max(0, min(1, c)) * 255) for c in rgb)


def palette(h):
    """Palette.swift: saturation and brightness of the original red, for any hue."""
    return {
        "skinTop": hexc(hsv(h + 0.0077, 0.684, 0.95)), "skin": hexc(hsv(h + 0.0025, 0.733, 0.90)),
        "skinBottom": hexc(hsv(h - 0.0026, 0.778, 0.81)),
        "hornLight": hexc(hsv(h + 0.0048, 0.673, 0.52)), "hornDark": hexc(hsv(h - 0.009, 0.73, 0.26)),
    }


# Idle proportions (ImpRenderer.size): a 100x100 design space.
CX, BOTTOM, RX, TOP, BASE = 50.0, 84.0, 33.0, 33.0, 19.0
CY = BOTTOM - BASE


def on_ball(lon, lat):
    return (math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon))


def project(v):
    return CX + RX * v[0], CY + v[1] * (TOP if v[1] < 0 else BASE)


def head_path():
    """Head.point(theta) with the idle face (round dome, no sag/peak/wobble)."""
    pts = []
    n = 96
    for i in range(n):
        th = -math.pi / 2 + i / n * 2 * math.pi
        c, s = math.cos(th), math.sin(th)
        k = max(0, s) ** 1.5
        ex, ey = 2 / (2 + 0.25 * k), 2 / (2 + 1.6 * k)
        x = RX * math.copysign(abs(c) ** ex, c)
        y = (TOP if s < 0 else BASE) * math.copysign(abs(s) ** ey, s)
        pts.append((CX + x, CY + y))
    return "M" + "L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + "Z"


def hull(points):
    p = sorted(points)
    if len(p) < 3:
        return []

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    def chain(seq):
        h = []
        for pt in seq:
            while len(h) >= 2 and cross(h[-2], h[-1], pt) <= 0:
                h.pop()
            h.append(pt)
        return h[:-1]
    return chain(p) + chain(p[::-1])


def horn(side):
    """Horn.swift, at the idle pose: a tube along a short curling spine, as front/back hull unions."""
    def add(a, b): return tuple(x + y for x, y in zip(a, b))
    def sub(a, b): return tuple(x - y for x, y in zip(a, b))
    def mul(a, k): return tuple(x * k for x in a)
    def dot(a, b): return sum(x * y for x, y in zip(a, b))
    def cross3(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
    def norm(a): return mul(a, 1 / max(1e-9, math.sqrt(dot(a, a))))

    root = on_ball(side * 0.9, -0.6)
    axis = norm(add(mul(root, 0.62), (0, -0.38, 0)))
    sideways = (side, 0, 0)
    out = norm(sub(sideways, mul(axis, dot(sideways, axis))))
    length, curl, r_base, r_tip, embed, rings, segs = 0.23, -0.085, 0.145, 0.042, 0.5, 14, 16
    origin = project(root)

    def screen(p):
        r = sub(p, root)
        return origin[0] + r[0] * RX, origin[1] + r[1] * RX

    def spine(t): return add(add(root, mul(axis, length * t)), mul(out, curl * max(0, t) ** 2.6))
    def tangent(t): return norm(add(mul(axis, length), mul(out, curl * 2.6 * max(0, t) ** 1.6)))

    def radius(t):
        k = max(0, t)
        return r_tip + (r_base - r_tip) * (1 - k ** 1.4) * (1 - 0.25 * k)

    ts = [-embed] + [1 - (1 - i / rings) ** 1.3 for i in range(rings + 1)]
    ring_pts = []
    for t in ts:
        c, tan = spine(t), tangent(t)
        u = norm(sub(out, mul(tan, dot(out, tan))))
        w = cross3(tan, u)
        ring_pts.append([screen(add(c, mul(add(mul(u, math.cos(ph)), mul(w, math.sin(ph))), radius(t))))
                         for ph in (k / segs * 2 * math.pi for k in range(segs))])
    front, back = [], []

    def put(points, t):
        p = spine(t)
        (front if dot(p, p) > 1 and p[2] > 0 else back).append(hull(points))
    for i in range(len(ts) - 1):
        put(ring_pts[i] + ring_pts[i + 1], (ts[i] + ts[i + 1]) / 2)
    tip, tr = screen(spine(1)), r_tip * RX
    put([(tip[0] + tr * math.cos(ph), tip[1] + tr * math.sin(ph))
         for ph in (k / segs * 2 * math.pi for k in range(segs))], 1)
    mid = screen(spine(0.4))
    base_r = r_base * RX
    light = (mid[0] - base_r * 0.35, mid[1] - base_r * 0.3)

    def d(hulls): return "".join("M" + "L".join(f"{x:.1f} {y:.1f}" for x, y in h) + "Z" for h in hulls if h)
    return d(back), d(front), light, base_r


_HEAD = head_path()
_HORNS = {side: horn(side) for side in (-1, 1)}


def imp_svg(hue, uid, label, size_class="", eyes_look=False, shadow=True):
    """The idle Imp as inline SVG, in the colours the app derives from `hue`."""
    p = palette(hue)
    lx, ly = project(on_ball(-0.35, -0.5))
    defs = [
        f'<linearGradient id="{uid}s" gradientUnits="userSpaceOnUse" x1="{CX}" y1="{CY - TOP}" x2="{CX}" y2="{CY + BASE}">'
        f'<stop offset="0" stop-color="{p["skinTop"]}"/><stop offset=".5" stop-color="{p["skin"]}"/>'
        f'<stop offset="1" stop-color="{p["skinBottom"]}"/></linearGradient>',
        f'<radialGradient id="{uid}l" gradientUnits="userSpaceOnUse" cx="{lx:.1f}" cy="{ly:.1f}" r="{RX * 0.8:.1f}">'
        '<stop offset="0" stop-color="#fff" stop-opacity=".14"/><stop offset=".5" stop-color="#fff" stop-opacity=".05"/>'
        '<stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>',
        f'<linearGradient id="{uid}o" gradientUnits="userSpaceOnUse" x1="0" y1="{CY + BASE * 0.35:.1f}" x2="0" y2="{CY + BASE}">'
        '<stop offset="0" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".07"/></linearGradient>',
        '<radialGradient id="%sw"><stop offset="0" stop-color="#000" stop-opacity=".28"/>'
        '<stop offset=".6" stop-color="#000" stop-opacity=".1"/><stop offset="1" stop-color="#000" stop-opacity="0"/></radialGradient>' % uid,
        f'<clipPath id="{uid}c"><path d="{_HEAD}"/></clipPath>',
    ]
    horns_back, horns_front = [], []
    for side, tag in ((-1, "a"), (1, "b")):
        back, front, (hx, hy), br = _HORNS[side]
        defs.append(f'<radialGradient id="{uid}{tag}" gradientUnits="userSpaceOnUse" cx="{hx:.1f}" cy="{hy:.1f}" r="{br * 1.7:.1f}">'
                    f'<stop offset="0" stop-color="{p["hornLight"]}"/><stop offset="1" stop-color="{p["hornDark"]}"/></radialGradient>')
        horns_back.append(f'<path d="{back}" fill="url(#{uid}{tag})"/>')
        horns_front.append(f'<path d="{front}" fill="url(#{uid}{tag})"/>')
    eyes = []
    for side in (-1, 1):
        n = on_ball(side * 0.46, 0.12)
        cx, cy = project(n)
        phi = math.degrees(math.atan2(n[1], n[0]))
        eyes.append(f'<ellipse rx="6.6" ry="9" fill="#fffcfa" transform="translate({cx:.2f} {cy:.2f}) rotate({phi:.1f}) '
                    f'scale({max(0.2, n[2]):.3f} 1) rotate({-phi:.1f})"/>')
    sh = (f'<ellipse cx="{CX}" cy="{BOTTOM + 1.5}" rx="{RX * 0.85 + 6:.1f}" ry="{(RX * 0.85 + 6) * 0.22:.1f}" fill="url(#{uid}w)"/>'
          if shadow else "")
    look = ' class="look"' if eyes_look else ""
    return (f'<svg class="imp {size_class}" viewBox="0 0 100 100" role="img" aria-label="{E(label)}" focusable="false">'
            f'<title>{E(label)}</title><defs>{"".join(defs)}</defs>{sh}'
            f'<g class="body">{"".join(horns_back)}<path d="{_HEAD}" fill="url(#{uid}s)"/>'
            f'<g clip-path="url(#{uid}c)"><path d="{_HEAD}" fill="url(#{uid}l)"/><path d="{_HEAD}" fill="url(#{uid}o)"/>'
            f'<g{look}><g class="eyes">{"".join(eyes)}</g></g></g>{"".join(horns_front)}</g></svg>')


def hue_name(h):
    h = h % 1
    names = [(0.04, "red"), (0.12, "orange"), (0.19, "amber"), (0.28, "yellow-green"), (0.45, "green"), (0.53, "teal"),
             (0.66, "blue"), (0.74, "indigo"), (0.82, "purple"), (0.93, "pink"), (1.01, "red")]
    return next(n for limit, n in names if h < limit)


def glyph_svg(kind, label):
    """A neutral kit glyph (no Imp in it): a bolt for triggers, a sparkle with motion arcs for animations, a gear for tools."""
    if kind == "animations":
        art = ('<path d="M50 10C53 34 58 42 82 46 58 50 53 58 50 82 47 58 42 50 18 46 42 42 47 34 50 10z" fill="currentColor"/>'
               '<path d="M78 66a22 22 0 0 1-14 16M22 66a22 22 0 0 0 14 16" fill="none" stroke="currentColor" stroke-width="6" stroke-linecap="round"/>'
               '<circle cx="80" cy="18" r="5" fill="currentColor"/><circle cx="20" cy="22" r="4" fill="currentColor"/>')
    elif kind == "triggers":
        art = '<path d="M56 14 28 54h20l-5 32 29-42H52z" fill="currentColor"/>'
    else:
        teeth = "".join(f'<rect x="45" y="12" width="10" height="16" rx="3" transform="rotate({a} 50 50)" fill="currentColor"/>'
                        for a in range(0, 360, 45))
        art = (f'{teeth}<circle cx="50" cy="50" r="27" fill="currentColor"/><circle cx="50" cy="50" r="11" fill="var(--glyph-hole)"/>')
    return (f'<svg class="glyph" viewBox="0 0 100 100" role="img" aria-label="{E(label)}" focusable="false"><title>{E(label)}</title>'
            f'<rect x="6" y="6" width="88" height="88" rx="26" fill="var(--glyph-bg)"/><g transform="translate(14 14) scale(.72)">{art}</g></svg>')


def avatar(kit, uid, size_class="", look=False):
    if kit.imps:
        imp = kit.imps[0]
        hue = float(imp.get("hue", 0.0))
        return imp_svg(hue, uid, f"{imp.get('name', 'Imp')}, a {hue_name(hue)} Imp", size_class, look)
    label = {"triggers": "A pack of triggers", "tools": "A pack of tools", "animations": "A pack of animations"}[kit.primary]
    return glyph_svg(kit.primary, label)


# ---------------------------------------------------------------- words

def clock(m):
    return f"{m // 60 % 24:02d}:{m % 60:02d}"


def keys_text(text):
    names = {"ctrl": "⌃", "control": "⌃", "ctl": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥", "shift": "⇧",
             "cmd": "⌘", "command": "⌘", "meta": "⌘"}
    parts = [p for p in re.split(r"[+\- ]", text) if p]
    return "".join(names.get(p.lower(), p.upper()) for p in parts[:-1]) + (parts[-1].upper() if parts else "")


def _num(w, default):
    v = w.get("number")
    return default if v is None else int(v)


def when_text(w, condition=False):
    """Mirrors Trigger.summary / conditionSummary in the app."""
    k = w.get("kind")
    on = w.get("flag", True)
    word = (w.get("text") or "").strip()
    if k == "keys":
        return "You press " + keys_text(w.get("keys", ""))
    if k == "clicks":
        n = _num(w, 1)
        return "1 click on the Imp" if n == 1 else f"{n} clicks on the Imp"
    if k == "battery":
        return f"Battery below {_num(w, 20)} %"
    if k == "charger":
        return ("On the charger" if on else "On battery") if condition else ("Charger plugged in" if on else "Charger unplugged")
    if k == "app":
        if condition:
            return f"{word} is in front" if word else "Any app in front"
        return f"{word} comes to the front" if word else "Any app comes to the front"
    if k == "website":
        return f"{word} is open" if condition and word else (f"On {word}" if word else "Any website")
    if k == "time":
        m = w.get("text")
        mm = re.match(r"^(\d{1,2}):(\d{2})$", (m or "").strip())
        return "Every day at " + (clock(int(mm[1]) * 60 + int(mm[2])) if mm else (m or clock(_num(w, 540))))
    if k == "every":
        n = _num(w, 60)
        return "Every hour" if n == 60 else (f"Every {n // 60} hours" if n % 60 == 0 else f"Every {n} min")
    if k == "back":
        return f"You come back after {_num(w, 15)} min away"
    if k == "wake":
        return "The Mac wakes up"
    if k == "start":
        return "Imp starts"
    if k == "busy":
        return f"Processor above {_num(w, 85)} %"
    if k == "hot":
        return "The Mac is hot" if condition else "The Mac runs hot"
    if k == "offline":
        return ("Offline" if on else "Online") if condition else ("Network goes away" if on else "Network comes back")
    if k == "hours":
        a, _, b = (w.get("text") or "").partition("-")
        return f"Between {a.strip()} and {b.strip()}"
    return str(k)


DO_TEXT = {"ask": "Asks the Imp", "type": "Opens a text box", "talk": "Starts listening", "chat": "Opens the chat",
           "settings": "Opens the Imp's settings"}


def command_line(server):
    return " ".join([server.get("command", "")] + [str(a) for a in server.get("args") or []]).strip()


def runtime_note(server):
    cmd = (server.get("command") or "").split()
    first = cmd[0] if cmd else ""
    return {"npx": "Needs Node.js (npx)", "uvx": "Needs uv (uvx)", "node": "Needs Node.js", "docker": "Needs Docker"}.get(first, "")


# ---------------------------------------------------------------- HTML

def head(title, desc, base, rel, canonical, extra=""):
    return f"""<!doctype html>
<html lang="en" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{E(title)}</title>
<meta name="description" content="{E(desc)}">
<meta name="color-scheme" content="dark light">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer">
<link rel="icon" href="{rel}favicon.svg" type="image/svg+xml">
<link rel="canonical" href="{E(canonical)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Imp Kits">
<meta property="og:title" content="{E(title)}">
<meta property="og:description" content="{E(desc)}">
<meta property="og:url" content="{E(canonical)}">
<meta property="og:image" content="{E(base)}/og.png">
<meta property="og:image:alt" content="Imp, tiny desktop imps, on a Mac desktop">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{E(title)}">
<meta name="twitter:description" content="{E(desc)}">
<meta name="twitter:image" content="{E(base)}/og.png">
<script src="{rel}assets/theme.js"></script>
<link rel="stylesheet" href="{rel}assets/site.css">
{extra}</head>
"""


def topbar(rel, current=""):
    def a(href, text, key):
        cur = ' aria-current="page"' if key == current else ""
        return f'<a href="{href}"{cur}>{text}</a>'
    return f"""<header class="top">
<a class="brand" href="{rel or './'}"><span class="brand-imp" aria-hidden="true">{imp_svg(0.0, "brand", "", "tiny", shadow=False)}</span><span>Imp Kits</span></a>
<nav aria-label="Main">
{a(rel or './', "Gallery", "gallery")}{a(rel + "add/", "Add yours", "add")}<a href="{REPO}">Imp on GitHub</a>
<button type="button" class="theme" id="theme" aria-label="Switch between dark and light" title="Dark / light"><span aria-hidden="true"></span></button>
</nav>
</header>"""


def footer(rel):
    return f"""<footer class="foot">
<p>Imp Kits is a community collection of setups for <a href="{REPO}">Imp</a>. This page loads nothing from anywhere else: no fonts, no analytics, no trackers.</p>
<p><a href="{rel}add/">Add yours</a> · <a href="{FORMAT_DOCS}">Kit format</a> · <a href="{REGISTRY_DOCS}">Contributing</a> · <a href="{rel}index.json">index.json</a></p>
</footer>
<script src="{rel}assets/site.js" defer></script>
</body>
</html>
"""


def badges(kit, full=False):
    out = []
    if kit.runs_commands:
        out.append('<span class="badge warn" title="Part of this kit starts a program on your Mac when you add it.">Runs commands on your Mac</span>')
    if kit.needs_keys:
        out.append('<span class="badge warn">Needs keys</span>')
    if kit.controls_mac:
        out.append('<span class="badge warn" title="An Imp in this kit can take screenshots, click and type in other apps.">Controls your Mac</span>')
    out.append(f'<span class="badge">Needs Imp {E(kit.min_imp)}+</span>')
    return "".join(out)


def counts(kit):
    parts = []
    n_imps, n_trig, n_tools, n_anim = len(kit.imps), len(kit.all_triggers), len(kit.servers), len(kit.all_animations)
    for n, one, many in ((n_imps, "Imp", "Imps"), (n_anim, "animation", "animations"),
                         (n_trig, "trigger", "triggers"), (n_tools, "tool", "tools")):
        if n:
            parts.append(f"{n} {one if n == 1 else many}")
    return " · ".join(parts)


def card(kit, i):
    types = " ".join(kit.types)
    search = " ".join([kit.name, kit.summary, kit.about, kit.author, " ".join(kit.tags),
                       " ".join(str(x.get("name", "")) for x in kit.imps), " ".join(kit.servers),
                       " ".join(str(x.get("name", "")) for x in kit.all_animations)]).lower()
    tags = "".join(f'<li>#{E(t)}</li>' for t in kit.tags[:4])
    type_labels = " · ".join(dict(TYPES)[t] for t in kit.types)
    return f"""<li class="card" data-types="{E(types)}" data-tags="{E(' '.join(kit.tags))}" data-search="{E(search)}" style="--delay:{(i * 0.9) % 4.7:.1f}s">
<div class="card-art">{avatar(kit, f'c{i}')}</div>
<div class="card-body">
<p class="kind">{E(type_labels)}</p>
<h3><a href="k/{kit.slug}/">{E(kit.name)}</a></h3>
<p class="summary">{E(kit.summary)}</p>
<p class="badges">{badges(kit)}</p>
<ul class="tags" aria-label="Tags">{tags}</ul>
<p class="meta"><span>by {E(kit.author)}</span><span>{E(counts(kit))}</span></p>
</div>
</li>"""


def gallery_page(kits, base):
    freq = {}
    for k in kits:
        for t in k.tags:
            freq[t] = freq.get(t, 0) + 1
    all_tags = sorted(freq, key=lambda t: (-freq[t], t))
    present = [(key, label) for key, label in TYPES if any(key in k.types for k in kits)]
    type_btns = ('<button type="button" class="seg" data-type="all" aria-pressed="true">All</button>'
                 + "".join(f'<button type="button" class="seg" data-type="{k}" aria-pressed="false">{l}</button>' for k, l in present))
    shown_tags = 9
    tag_btns = "".join(
        f'<button type="button" class="chip{" extra" if n >= shown_tags else ""}" data-tag="{E(t)}" aria-pressed="false"'
        f'{" hidden" if n >= shown_tags else ""}>#{E(t)}</button>' for n, t in enumerate(all_tags))
    if len(all_tags) > shown_tags:
        tag_btns += '<button type="button" class="chip more-tags" id="more-tags" aria-expanded="false">More tags</button>'
    cards = "\n".join(card(k, i) for i, k in enumerate(kits))
    hero_imp = imp_svg(0.0, "hero", "Imp, a soft red mochi head with two little horns and two white eyes", "hero-imp", eyes_look=True)
    desc = "Setups to share with your Imp: whole Imps, animations, triggers and tools, added in one click and always reviewed first."
    return head("Imp Kits: setups for tiny desktop imps", desc, base, "", base + "/") + f"""<body>
<a class="skip" href="#kits">Skip to the kits</a>
{topbar("", "gallery")}
<main>
<section class="hero">
<div class="embers" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i><i></i><i></i></div>
<div class="hero-text">
<p class="eyebrow">Community registry</p>
<h1>Little setups<br>for little imps</h1>
<p class="lede">Whole Imps with their own personalities, packs of triggers, borrowed tools. Press <b>Add to Imp</b> and Imp opens a review: you see everything, tick what you want, and nothing is added without your say.</p>
<p class="cta"><a class="btn primary" href="#kits">Browse the kits</a><a class="btn" href="add/">Add yours</a></p>
</div>
<div class="hero-art">
<div class="arch" aria-hidden="true"><div class="arch-in"></div></div>
<button type="button" class="hero-imp-wrap" id="hero-imp" aria-label="Poke the Imp">{hero_imp}</button>
<div class="pedestal" aria-hidden="true"></div>
</div>
</section>

<section class="browse" id="kits" aria-labelledby="kits-h">
<div class="browse-head"><h2 id="kits-h">The kits</h2><p class="count" id="count" role="status" aria-live="polite">{len(kits)} kits</p></div>
<div class="controls">
<div class="search"><label for="q" class="vh">Search kits</label>
<input id="q" type="search" placeholder="Search kits, tags, authors…" autocomplete="off" spellcheck="false"></div>
<div class="segs" role="group" aria-label="Kind of kit">{type_btns}</div>
</div>
<div class="chips" role="group" aria-label="Filter by tag">{tag_btns}</div>
<ul class="grid" id="grid">
{cards}
</ul>
<div class="empty" id="empty" hidden>
<p>No kit matches that.</p><button type="button" class="btn" id="clear">Clear the filters</button>
</div>
</section>

<section class="band" aria-labelledby="add-h">
<div><h2 id="add-h">Made a setup you love?</h2>
<p>Export it from Imp (<b>Me › Share</b>), check it has no secrets, and send a pull request. It takes about five minutes.</p></div>
<a class="btn primary" href="add/">How to add yours</a>
</section>
</main>
{footer("")}"""


def section_triggers(triggers, heading="Triggers"):
    if not triggers:
        return ""
    items = []
    for t in triggers:
        w = t.get("when") or {}
        conds = "".join(f'<li>{E(when_text(c, True))}</li>' for c in t.get("only_if") or [])
        do = DO_TEXT.get(t.get("do", "ask"), "Asks the Imp")
        prompt = t.get("prompt", "")
        clip = '<span class="badge">Sends what you copied</span>' if t.get("with_clipboard") else ""
        items.append(f"""<li class="item">
<div class="item-head"><h4>{E(t.get('name', 'Trigger'))}</h4>{clip}</div>
<dl class="kv"><dt>When</dt><dd>{E(when_text(w))}</dd>
{f'<dt>Only if</dt><dd><ul class="plain">{conds}</ul></dd>' if conds else ''}
<dt>Then</dt><dd>{E(do)}</dd></dl>
{f'<blockquote class="prompt"><span class="vh">Prompt: </span>{E(prompt)}</blockquote>' if prompt else ''}
</li>""")
    return f'<section class="block"><h3>{E(heading)}</h3><ul class="items">{"".join(items)}</ul></section>'


def starts_text(a):
    starts = [str(x) for x in a.get("starts") or []] if isinstance(a.get("starts"), list) else []
    return ", ".join(STARTS.get(x, x) for x in starts)


STARTS = {"idle": "when idle", "poke": "a poke", "circle": "circling the cursor", "swish": "a swish", "stroke": "a stroke",
          "favoriteColor": "its favorite color", "tickle": "a tickle", "hold": "being held", "pickUp": "being picked up",
          "shake": "a shake", "drop": "a drop", "rush": "a rush", "linger": "the cursor lingering", "stare": "a stare",
          "dangle": "dangling", "comeback": "you coming back"}


def beat_label(b):
    bits = [str(b.get(k)) for k in ("mood", "glyph") if b.get(k)]
    if b.get("hop"):
        bits.append("hop")
    if not bits and b.get("look"):
        bits.append("look")
    return " + ".join(bits) or "pause"


def timeline(beats):
    segs = []
    for b in beats:
        d = float(b.get("duration", 0.05))
        label = beat_label(b)
        segs.append(f'<li style="flex:{d:.3f} 1 0" class="beat{" hop" if b.get("hop") else ""}" title="{E(label)}, {d:g} s">'
                    f'<span>{E(label)}</span></li>')
    return f'<ol class="timeline" aria-label="Beats">{"".join(segs)}</ol>'


def animation_item(a):
    beats = [b for b in a.get("beats") or [] if isinstance(b, dict) and is_num(b.get("duration"))]
    total = sum(b["duration"] for b in beats)
    rows = []
    if a.get("replaces"):
        rows.append(f'<dt>Replaces</dt><dd>the built-in <code>{E(str(a["replaces"]))}</code></dd>')
    starts = starts_text(a)
    if starts:
        rows.append(f'<dt>Starts with</dt><dd>{E(starts)}</dd>')
    rows.append(f'<dt>Length</dt><dd>{len(beats)} beat{"" if len(beats) == 1 else "s"}, {total:.1f} s</dd>')
    about = a.get("about")
    return (f'<li class="item"><div class="item-head"><h4>{E(str(a.get("name", "Animation")))}</h4>'
            + (f'<span class="badge">Replaces {E(str(a["replaces"]))}</span>' if a.get("replaces") else "") + '</div>'
            + (f'<p class="muted anim-about">{E(about)}</p>' if isinstance(about, str) and about else "")
            + f'<dl class="kv">{"".join(rows)}</dl>{timeline(beats)}</li>')


def section_animations(anims, heading="Animations", nested=False):
    if not anims:
        return ""
    body = f'<ul class="items">{"".join(animation_item(a) for a in anims)}</ul>'
    if nested:
        return f'<h5>{E(heading)}</h5>{body}'
    return f'<section class="block"><h3>{E(heading)}</h3>{body}</section>'


def traits_text(t):
    if not isinstance(t, dict):
        return ""
    def v(k):
        return t.get(k) if is_num(t.get(k)) else 0
    out = []
    if v("lids") >= 0.15: out.append("heavy lids")
    if v("slant") <= -0.1: out.append("worried brows")
    if v("slant") >= 0.1: out.append("angry brows")
    if v("eyes") >= 0.05: out.append("big eyes")
    if v("eyes") <= -0.05: out.append("small eyes")
    if v("squint") >= 0.2: out.append("squinting")
    if v("squint") <= -0.2: out.append("wide-eyed")
    if v("horns") >= 5: out.append("horns up")
    if v("horns") <= -5: out.append("horns down")
    if v("blush") >= 0.15: out.append("blushing")
    if abs(v("tilt")) >= 2: out.append("head tilted")
    tempo = t.get("tempo") if is_num(t.get("tempo")) else 1
    if tempo <= 0.9: out.append("slow")
    if tempo >= 1.1: out.append("quick")
    text = ", ".join(out)
    return text[:1].upper() + text[1:]


def server_item(name, s):
    if "url" in s:
        what = f'<dt>Address</dt><dd><code>{E(s["url"])}</code></dd><dd class="note">A remote tool: what you ask goes to that address.</dd>'
    else:
        note = runtime_note(s)
        what = (f'<dt>Runs</dt><dd><code>{E(command_line(s))}</code></dd>'
                + (f'<dd class="note">{E(note)}</dd>' if note else ""))
    needs = list((s.get("env") or {}).keys()) + list((s.get("headers") or {}).keys())
    if needs:
        what += f'<dt>You fill in</dt><dd>{", ".join(f"<code>{E(n)}</code>" for n in needs)}</dd>'
    return f'<li class="item"><div class="item-head"><h4>{E(name)}</h4></div><dl class="kv">{what}</dl></li>'


def section_tools(servers):
    if not servers:
        return ""
    return f'<section class="block"><h3>Tools</h3><ul class="items">{"".join(server_item(n, s) for n, s in servers.items())}</ul></section>'


def section_imp(kit, imp, i):
    hue = float(imp.get("hue", 0.0))
    brain = imp.get("brain") or {}
    model = brain.get("model", "")
    service = (brain.get("service") or {}).get("name") or (brain.get("service") or {}).get("baseURL", "")
    model_text = f"{model} on {service}" if model and service else (model or service or "Your default model")
    groups = "".join(f'<li class="{"on" if tool_on(imp, g) else "off"}"><span class="vh">{"On" if tool_on(imp, g) else "Off"}: </span>{lbl}</li>'
                     for g, lbl in TOOL_GROUPS)
    shell = imp.get("shell", True)
    own_tools = "".join(server_item(n, kit.servers[n]) for n in imp.get("mcpServers") or [] if n in kit.servers)
    personality = imp.get("personality", "")
    return f"""<li class="item imp-item">
<div class="imp-id">{imp_svg(hue, f'i{i}', f"{imp.get('name', 'Imp')}, a {hue_name(hue)} Imp", 'small')}
<div><h4>{E(imp.get('name', 'Imp'))}</h4><p class="muted">{E(model_text)}</p>{f'<p class="muted small traits">{E(traits_text(imp.get("traits")))}</p>' if traits_text(imp.get("traits")) else ''}</div></div>
<h5>Personality</h5>
<blockquote class="prompt clamp" id="p{i}">{E(personality)}</blockquote>
<button type="button" class="more" data-more="p{i}" aria-expanded="false" aria-controls="p{i}">Read it all</button>
<h5>What it can do</h5>
<ul class="pills" aria-label="Tool groups">{groups}<li class="{'on' if shell else 'off'}"><span class="vh">{'On' if shell else 'Off'}: </span>Terminal commands</li></ul>
{f'<h5>Borrowed tools</h5><ul class="items nested">{own_tools}</ul>' if own_tools else ''}
{section_animations(imp.get('animations') if isinstance(imp.get('animations'), list) else [], 'Its animations', True)}
{section_triggers(imp.get('triggers') or [], 'Its triggers').replace('<section class="block">', '<div class="block nested-block">').replace('</section>', '</div>') if imp.get('triggers') else ''}
</li>"""


def safety(kit):
    pts = ['<li><b>Nothing is added without your say.</b> Imp shows every Imp, trigger and tool first, and you tick what you want.</li>']
    for name, s in kit.servers.items():
        if "command" in s:
            pts.append(f'<li><b>Runs a program on your Mac:</b> <code>{E(command_line(s))}</code> (the tool “{E(name)}”). '
                       'It runs with your permissions, like any program you start yourself.</li>')
        elif "url" in s:
            pts.append(f'<li><b>Talks to a web address:</b> <code>{E(s["url"])}</code> (the tool “{E(name)}”).</li>')
    for imp in kit.imps:
        if tool_on(imp, "computer"):
            pts.append(f'<li><b>{E(imp["name"])} controls your Mac:</b> it can take screenshots and click and type in other apps. '
                       'Imp asks for macOS permission first, and you can switch it off per Imp.</li>')
        if imp.get("shell", True):
            pts.append(f'<li><b>{E(imp["name"])} may run terminal commands</b> when you ask it to. Switch “Terminal commands” off on its page if you do not want that.</li>')
    if kit.needs_keys:
        pts.append('<li><b>Needs keys you fill in yourself.</b> The kit has the names, never the values.</li>')
    pts.append('<li><b>Personalities and triggers steer what an Imp does with its tools.</b> Read them above before you add.</li>')
    pts.append('<li><b>No secrets, no chats.</b> Kits in this registry carry no keys and no conversations. A kit can never add a model service for you.</li>')
    return f'<section class="block safety"><h3>Before you add it</h3><ul class="checks">{"".join(pts)}</ul></section>'


def kit_page(kit, base):
    page, add = kit.page_url(base), kit.add_url(base)
    rel = "../../"
    inside = ""
    if kit.imps:
        inside += f'<section class="block"><h3>{"The Imp" if len(kit.imps) == 1 else "The Imps"}</h3><ul class="items">{"".join(section_imp(kit, imp, i) for i, imp in enumerate(kit.imps))}</ul></section>'
    inside += section_animations(kit.animations)
    inside += section_triggers(kit.triggers)
    inside += section_tools(kit.loose_servers)
    pretty = json.dumps(kit.data, indent=2, ensure_ascii=False)
    desc = f"{kit.summary} A kit for Imp, by {kit.author}."
    return head(f"{kit.name} · Imp Kits", desc, base, rel, page) + f"""<body>
<a class="skip" href="#main">Skip to the kit</a>
{topbar(rel)}
<main id="main" class="kit">
<p class="crumbs"><a href="{rel}">← All kits</a></p>
<section class="kit-hero">
<div class="kit-art">{avatar(kit, 'kh', 'big', look=True)}</div>
<div class="kit-intro">
<p class="kind">{E(' · '.join(dict(TYPES)[t] for t in kit.types))} · by {E(kit.author)}</p>
<h1>{E(kit.name)}</h1>
<p class="lede">{E(kit.summary)}</p>
<p class="badges">{badges(kit)}</p>
<p class="actions">
<a class="btn primary big" id="add" href="{E(add)}" data-slug="{kit.slug}">Add to Imp</a>
<button type="button" class="btn" id="copy-link" data-copy="{E(page)}">Copy link</button>
<a class="btn" href="{rel}kits/{kit.slug}.json" download="{kit.slug}.json">Download .json</a>
</p>
<p class="muted small">{E(counts(kit))} · works with Imp {E(kit.min_imp)} or newer</p>
</div>
</section>

<div id="install" class="install" hidden role="region" aria-labelledby="install-h" tabindex="-1">
<h2 id="install-h">Imp didn't open. Is it installed?</h2>
<p>Add to Imp hands the kit to the Imp app on your Mac. If you don't have it yet, get it first, then press the button again.</p>
<p class="actions"><a class="btn primary" href="{RELEASES_DMG}">Get Imp</a></p>
<p class="muted small">Or with Homebrew:</p>
<div class="cmd"><code id="brew">{E(BREW)}</code><button type="button" class="btn small" data-copy="{E(BREW)}">Copy</button></div>
<p class="muted small">Already installed? Update to Imp {E(kit.min_imp)} or newer (<code>brew upgrade --cask imp</code>) and try again.</p>
</div>

<section class="block"><h3>About</h3><p class="about">{E(kit.about)}</p></section>
{safety(kit)}
<div class="inside"><h2>What's inside</h2>{inside}</div>

<section class="block">
<details class="json"><summary>View JSON</summary>
<div class="cmd right"><button type="button" class="btn small" data-copy-json="kit-json">Copy JSON</button></div>
<pre id="kit-json" tabindex="0"><code>{E(pretty)}</code></pre></details>
</section>
</main>
{footer(rel)}"""


def add_page(base):
    snippet = (f'<a class="add-to-imp" href="imp://add?url=https://example.com/my-kit.json">Add to Imp</a>')
    css = SNIPPET_CSS.strip()
    return head("Add your kit · Imp Kits", "How to share your own Imp setup in the Imp Kits registry.", base, "../", base + "/add/") + f"""<body>
<a class="skip" href="#main">Skip to the content</a>
{topbar("../", "add")}
<main id="main" class="prose">
<p class="crumbs"><a href="../">← All kits</a></p>
<h1>Add yours</h1>
<p class="lede">A kit is Imps, triggers and borrowed tools in one piece of JSON. Anyone can send one in.</p>
<ol class="steps">
<li><h2>Export it from Imp</h2><p>Open an Imp's page and choose <b>Me › Share</b> (or <b>All Imps › Manners › Export…</b> for several). For triggers or tools alone, use <b>Share as kit</b> in Settings. Save the <code>.json</code> file.</p></li>
<li><h2>Check it is safe to share</h2><ul>
<li>No keys, tokens or passwords anywhere. Imp blanks environment variables and header values for you; check command arguments yourself.</li>
<li>No chats (leave <b>Include chats</b> unticked), and nothing personal in prompts.</li>
<li>Only real tools from published packages, and say what each one does in <code>about</code>.</li></ul></li>
<li><h2>Add the registry details</h2><p>Add a <code>registry</code> block next to <code>name</code> and <code>about</code>. Imp ignores it; the gallery reads it.</p>
<pre><code>"registry": {{
  "author": "your name",
  "tags": ["planning", "memory"],
  "summary": "One line that says what it is for."
}}</code></pre></li>
<li><h2>Open a pull request</h2><p>Save the file as <code>registry/kits/your-kit-name.json</code> in <a href="{REPO}">the Imp repository</a>. A check runs it through Imp's own parser, so you see right away if something is off. A person reads it before it goes up.</p></li>
</ol>
<p><a class="btn primary" href="{REGISTRY_DOCS}">Contributing rules</a> <a class="btn" href="{FORMAT_DOCS}">The kit format</a></p>

<h2>An “Add to Imp” button for your own site</h2>
<p>If you host a kit yourself (over <code>https</code>, under 512 KB), put this on your page. Imp always shows a review before anything is added.</p>
<div class="demo">{snippet}</div>
<h3>HTML</h3>
<pre><code>{E(SNIPPET_HTML)}</code></pre>
<h3>CSS</h3>
<pre><code>{E(css)}</code></pre>
</main>
{footer("../")}"""


SNIPPET_HTML = """<a class="add-to-imp" href="imp://add?url=https://example.com/my-kit.json">Add to Imp</a>"""
SNIPPET_CSS = """
.add-to-imp {
  display: inline-block; padding: .65em 1.2em; border-radius: 999px;
  background: #c92f35; color: #fff; font: 600 1rem/1 system-ui, sans-serif;
  text-decoration: none; box-shadow: 0 2px 0 #8f1f27;
}
.add-to-imp:hover { background: #d93a40; }
.add-to-imp:focus-visible { outline: 3px solid #ffb86b; outline-offset: 3px; }
"""


# ---------------------------------------------------------------- the site

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def build(out, base):
    kits, errors = load_kits()
    if errors:
        print("Kit problems:", *errors, sep="\n  ", file=sys.stderr)
        return 1
    if not kits:
        print("No kits in registry/kits", file=sys.stderr)
        return 1
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for name in ("site.css", "site.js", "theme.js"):
        write(out / "assets" / name, (ROOT / "assets" / name).read_text(encoding="utf-8"))
    write(out / "favicon.svg", imp_svg(0.0, "fav", "Imp", shadow=False).replace('class="imp "', 'xmlns="http://www.w3.org/2000/svg" class="imp"', 1))
    shot = ROOT.parent / "docs" / "screenshot.png"
    if shot.exists():
        shutil.copy(shot, out / "og.png")
    write(out / "index.html", gallery_page(kits, base))
    write(out / "add" / "index.html", add_page(base))
    manifest = []
    for k in kits:
        write(out / "k" / k.slug / "index.html", kit_page(k, base))
        write(out / "kits" / f"{k.slug}.json", k.raw)
        manifest.append({
            "slug": k.slug, "name": k.name, "about": k.about, "summary": k.summary, "author": k.author, "tags": k.tags,
            "types": k.types, "formatVersion": k.version, "minImpVersion": k.min_imp,
            "imps": [{"name": i.get("name"), "hue": i.get("hue", 0.0)} for i in k.imps],
            "counts": {"imps": len(k.imps), "animations": len(k.all_animations), "triggers": len(k.all_triggers), "tools": len(k.servers)},
            "runsCommands": k.runs_commands, "needsKeys": k.needs_keys, "controlsMac": k.controls_mac,
            "page": k.page_url(base), "json": k.json_url(base), "add": k.add_url(base),
        })
    write(out / "index.json", json.dumps({"version": 1, "base": base, "kits": manifest}, indent=2, ensure_ascii=False) + "\n")
    write(out / ".nojekyll", "")
    print(f"Built {len(kits)} kits into {out}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(ROOT / "site"), help="output folder (default registry/site)")
    ap.add_argument("--base-url", default=DEFAULT_BASE, help=f"where the site will be served (default {DEFAULT_BASE})")
    a = ap.parse_args()
    return build(Path(a.out), a.base_url.rstrip("/"))


if __name__ == "__main__":
    sys.exit(main())
