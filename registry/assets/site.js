// Imp Kits: filtering, the little Imp's manners, copy buttons and "is Imp installed?". No network use.
(function () {
  "use strict";
  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Theme: dark and light, following the system until the button is pressed.
  var themeBtn = $("#theme");
  if (themeBtn) themeBtn.addEventListener("click", function () {
    var root = document.documentElement, t = root.getAttribute("data-theme");
    var dark = t === "dark" || (t === "auto" && !(window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches));
    var next = dark ? "light" : "dark";
    root.setAttribute("data-theme", next);
    try { localStorage.setItem("imp-theme", next); } catch (e) { /* ignore */ }
  });

  // Gallery: search, kind and tag filters.
  var grid = $("#grid");
  if (grid) {
    var cards = $$(".card", grid), q = $("#q"), count = $("#count"), empty = $("#empty");
    var type = "all", tags = {};
    var apply = function () {
      var words = q.value.toLowerCase().split(/\s+/).filter(Boolean), active = Object.keys(tags);
      var shown = 0;
      cards.forEach(function (c) {
        var text = c.getAttribute("data-search"), kinds = c.getAttribute("data-types").split(" "), own = c.getAttribute("data-tags").split(" ");
        var ok = words.every(function (w) { return text.indexOf(w) >= 0; }) &&
          (type === "all" || kinds.indexOf(type) >= 0) &&
          (!active.length || active.some(function (t) { return own.indexOf(t) >= 0; }));
        c.hidden = !ok;
        if (ok) shown++;
      });
      count.textContent = shown === 1 ? "1 kit" : shown + " kits";
      empty.hidden = shown > 0;
    };
    q.addEventListener("input", apply);
    $$(".seg").forEach(function (b) {
      b.addEventListener("click", function () {
        type = b.getAttribute("data-type");
        $$(".seg").forEach(function (o) { o.setAttribute("aria-pressed", String(o === b)); });
        apply();
      });
    });
    $$(".chip[data-tag]").forEach(function (b) {
      b.addEventListener("click", function () {
        var t = b.getAttribute("data-tag"), on = !tags[t];
        if (on) tags[t] = true; else delete tags[t];
        b.setAttribute("aria-pressed", String(on));
        apply();
      });
    });
    var moreTags = $("#more-tags");
    if (moreTags) moreTags.addEventListener("click", function () {
      var open = moreTags.getAttribute("aria-expanded") !== "true";
      $$(".chip.extra").forEach(function (c) { c.hidden = !open; });
      moreTags.setAttribute("aria-expanded", String(open));
      moreTags.textContent = open ? "Fewer tags" : "More tags";
    });
    $("#clear").addEventListener("click", function () {
      q.value = ""; type = "all"; tags = {};
      $$(".seg").forEach(function (o) { o.setAttribute("aria-pressed", String(o.getAttribute("data-type") === "all")); });
      $$(".chip[data-tag]").forEach(function (o) { o.setAttribute("aria-pressed", "false"); });
      apply(); q.focus();
    });
  }

  // The big Imps watch the pointer; the hero Imp hops when poked.
  var watchers = $$(".hero-imp, .imp.big").map(function (svg) { return { svg: svg, look: $(".look", svg) }; }).filter(function (w) { return w.look; });
  if (watchers.length && !reduce) {
    var aim = function (x, y) {
      watchers.forEach(function (w) {
        var r = w.svg.getBoundingClientRect(), dx = x - (r.left + r.width / 2), dy = y - (r.top + r.height * 0.6);
        var d = Math.max(1, Math.hypot(dx, dy)), k = Math.min(1, d / 260);
        w.look.style.transform = "translate(" + (dx / d * 4.2 * k).toFixed(2) + "px," + (dy / d * 2.4 * k).toFixed(2) + "px)";
      });
    };
    window.addEventListener("pointermove", function (e) { aim(e.clientX, e.clientY); }, { passive: true });
    window.addEventListener("pointerleave", function () { watchers.forEach(function (w) { w.look.style.transform = ""; }); });
  }
  var poke = $("#hero-imp");
  if (poke) poke.addEventListener("click", function () {
    poke.classList.remove("poke"); void poke.offsetWidth; if (!reduce) poke.classList.add("poke");
  });

  // Copy buttons.
  var copy = function (text, button) {
    var done = function () {
      var old = button.textContent;
      button.textContent = "Copied";
      setTimeout(function () { button.textContent = old; }, 1600);
    };
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(text).then(done, function () { fallback(text, done); });
    } else { fallback(text, done); }
  };
  var fallback = function (text, done) {
    var t = document.createElement("textarea");
    t.value = text; t.setAttribute("readonly", ""); t.style.position = "fixed"; t.style.opacity = "0";
    document.body.appendChild(t); t.select();
    try { document.execCommand("copy"); done(); } catch (e) { /* ignore */ }
    document.body.removeChild(t);
  };
  $$("[data-copy]").forEach(function (b) { b.addEventListener("click", function () { copy(b.getAttribute("data-copy"), b); }); });
  $$("[data-copy-json]").forEach(function (b) {
    b.addEventListener("click", function () { copy($("#" + b.getAttribute("data-copy-json")).textContent, b); });
  });

  // "Read it all" on long prompts.
  $$("[data-more]").forEach(function (b) {
    var box = $("#" + b.getAttribute("data-more"));
    if (box.scrollHeight <= box.clientHeight + 4) { b.hidden = true; box.classList.add("open"); return; }
    b.addEventListener("click", function () {
      var open = box.classList.toggle("open");
      b.setAttribute("aria-expanded", String(open));
      b.textContent = open ? "Show less" : "Read it all";
    });
  });

  // Add to Imp: if the page keeps focus and stays visible, no app took the link: offer to install it.
  var add = $("#add"), panel = $("#install");
  if (add && panel) add.addEventListener("click", function () {
    var left = false;
    var gone = function () { left = true; };
    var onVis = function () { if (document.hidden) left = true; };
    window.addEventListener("blur", gone);
    window.addEventListener("pagehide", gone);
    document.addEventListener("visibilitychange", onVis);
    setTimeout(function () {
      window.removeEventListener("blur", gone);
      window.removeEventListener("pagehide", gone);
      document.removeEventListener("visibilitychange", onVis);
      if (!left && !document.hidden) {
        panel.hidden = false;
        panel.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "center" });
        panel.focus({ preventScroll: true });
      }
    }, 1500);
  });
})();
