// Runs before the page paints, so the chosen theme never flashes. Nothing leaves the browser.
(function () {
  try {
    var t = (location.search.match(/[?&]theme=(light|dark)/) || [])[1] || localStorage.getItem("imp-theme");
    document.documentElement.setAttribute("data-theme", t === "light" || t === "dark" ? t : "auto");
  } catch (e) { /* storage blocked: follow the system */ }
})();
