// The toolbar popup: whether Imp is connected, and what it's been told about this tab.

const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);

function render(s) {
  const on = !!(s && s.connected);
  $("status").classList.toggle("on", on);
  $("status-text").textContent = on
    ? `Connected${s.browser ? ` · ${s.browser}` : ""}`
    : (s && s.connecting ? "Connecting…" : "Not connected");
  $("connected").hidden = !on;
  $("disconnected").hidden = on;
  if (on) {
    const page = s.page;
    $("page-title").textContent = page && page.title ? page.title : "Untitled page";
    $("page-url").textContent = page ? page.url : "Nothing yet: open a web page.";
  }
}

async function ask(type) {
  try { return await api.runtime.sendMessage({ type }); } catch { return null; }
}

$("reconnect").addEventListener("click", async () => {
  const button = $("reconnect");
  button.disabled = true;
  button.textContent = "Connecting…";
  render(await ask("reconnect"));
  // Give the socket a moment, then show how it went.
  setTimeout(async () => {
    render(await ask("status"));
    button.disabled = false;
    button.textContent = "Reconnect";
  }, 900);
});

(async () => {
  render(await ask("status"));
  // Keep it fresh while the popup is open (Imp may start meanwhile).
  setInterval(async () => render(await ask("status")), 1500);
})();
