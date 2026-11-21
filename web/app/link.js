// The page's link node on WebSockets: what chat/src/link/runner.rs is for the terminal app. The node
// (imp-engine, compiled to WebAssembly in ./pkg) decides everything. This file only moves bytes, does the
// Hop's handshake for it, waits at the Hop as a host, and keeps the book in localStorage.
//
// A browser can't open TCP, so every connection is a WebSocket: to the Hop (which takes WebSockets on its
// own port, server/hop/src/ws.rs), or straight to a device that takes them on its link port.

import init, { WebNode, qr_path } from './pkg/imp_web.js';

const BOOK = 'imp.web.book';
const DEVICE = 'imp.web.device';
const CONNECT_TIMEOUT = 5000;
/** How long a device's own address may take to answer a WebSocket. */
const DIRECT_TIMEOUT = 2000;
const GUEST_WAIT = 20000;
const RETRY_FIRST = 2000;
const RETRY_LONGEST = 60000;

const now = () => Date.now() / 1000;

function fromBase64(text) {
  const raw = atob(text);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

/**
 * The WebSocket address of a Hop given as host:port. An https page may only open wss://, which a proxy
 * in front of the Hop answers on port 443 (server/README.md). A plain http page talks to the Hop's own port.
 * `override` (from the page's settings) wins when set.
 */
export function hopSocketUrl(address, override) {
  if (override) return override;
  const at = address.lastIndexOf(':');
  const host = address.slice(0, at);
  const port = address.slice(at + 1);
  return location.protocol === 'https:' ? `wss://${host}/` : `ws://${host}:${port}/`;
}

/** Opens a WebSocket for bytes, or rejects when it doesn't open in time. */
function openSocket(url, wait = CONNECT_TIMEOUT) {
  return new Promise((resolve, reject) => {
    let ws;
    try {
      ws = new WebSocket(url);
    } catch (e) {
      reject(e);
      return;
    }
    ws.binaryType = 'arraybuffer';
    const timer = setTimeout(() => { ws.close(); reject(new Error('timeout')); }, wait);
    ws.onopen = () => { clearTimeout(timer); resolve(ws); };
    ws.onerror = () => { clearTimeout(timer); reject(new Error('could not connect')); };
  });
}

/**
 * Runs the Hop's handshake on an open socket. Resolves with `{ status, rest }`: status is `go` (the
 * link's bytes follow, `rest` holds the first of them), `rejected`, `busy`, `nobody` or `closed`.
 * `abort` (a promise) gives up early.
 */
function hopHandshake(ws, hop, wait) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (status, rest = new Uint8Array()) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      ws.onmessage = null;
      ws.onclose = null;
      resolve({ status, rest });
    };
    const timer = wait ? setTimeout(() => { ws.close(); finish('closed'); }, wait) : null;
    ws.onmessage = (e) => {
      let progress;
      try {
        progress = JSON.parse(hop.feed(new Uint8Array(e.data)));
      } catch {
        ws.close();
        finish('closed');
        return;
      }
      const reply = fromBase64(progress.reply);
      if (reply.length) ws.send(reply);
      if (progress.status) finish(progress.status, fromBase64(progress.rest));
    };
    ws.onclose = () => finish(hop.closed() || 'closed');
    ws.send(hop.hello());
  });
}

export class Link extends EventTarget {
  /**
   * @param {object} options `name` (what other devices see), `hopSocket` (a ws:// or wss:// address that
   * replaces the one made from a Hop's host:port).
   */
  constructor(options = {}) {
    super();
    this.options = options;
    this.node = null;
    this.sockets = new Map(); // conn -> WebSocket
    this.hostWait = null; // the socket waiting at our own Hop
    this.hostRetry = RETRY_FIRST;
    this.hostGeneration = 0;
    this.timer = null;
  }

  async start() {
    await init();
    const saved = localStorage.getItem(BOOK);
    let id = localStorage.getItem(DEVICE);
    if (!id) {
      id = crypto.randomUUID();
      localStorage.setItem(DEVICE, id);
    }
    const name = this.options.name || 'Web';
    try {
      this.node = new WebNode(saved ? fromBase64(saved) : undefined, name, id);
    } catch (e) {
      // A book that can't be read is dropped, as the apps do, and the person hears the links were reset.
      localStorage.removeItem(BOOK);
      this.node = new WebNode(undefined, name, id);
      this.emit('problem', 'The saved links could not be read, so they were reset.');
    }
    this.node.start(now());
    this.timer = setInterval(() => this.run((n) => n.tick(now())), 500);
    this.flush();
  }

  stop() {
    if (!this.node) return;
    clearInterval(this.timer);
    this.run((n) => n.stop(now()));
    this.hostGeneration++;
    if (this.hostWait) this.hostWait.close();
    for (const ws of this.sockets.values()) ws.close();
    this.sockets.clear();
  }

  emit(type, detail) {
    this.dispatchEvent(new CustomEvent(type, { detail }));
  }

  /** Runs `job` on the node, then carries out what it asked for. */
  run(job) {
    const result = job(this.node);
    this.flush();
    return result;
  }

  device() {
    return JSON.parse(this.node.device());
  }

  state() {
    return JSON.parse(this.node.state());
  }

  /** Waits at `hop` (host:port) so devices that scan this page's code can reach it, or stops waiting. */
  setHop(hop) {
    this.run((n) => n.set_hop(hop || undefined));
  }

  /** Joins with a code (implink://join?...). The answer comes as a `joined` event. */
  join(code) {
    return this.run((n) => n.join(code, now()));
  }

  /** A code for another device to scan, with its QR path. Call `inviteHidden` when it's gone. */
  invite() {
    const url = this.run((n) => n.invite(now()));
    return { url, qr: JSON.parse(qr_path(url)) };
  }

  inviteHidden() {
    this.run((n) => n.invite_hidden(now()));
  }

  /** Sends a link message (wire JSON as an object) to a device. */
  send(message, to) {
    return this.run((n) => n.send(JSON.stringify(message), to));
  }

  accept(transfer) {
    return this.run((n) => n.accept(transfer, now()));
  }

  decline(transfer, reason) {
    this.run((n) => n.decline(transfer, reason));
  }

  /** Throws a visiting Imp off `side` at `height` (0 top, 1 bottom). `{ transfer, to }` or `{ bounce }`. */
  throwImp(imp, side, height, speed) {
    return JSON.parse(this.run((n) => n.throw(imp, side, height, speed, now())));
  }

  /** The doors on `side` for a visiting Imp, and the one a throw at `height` goes to: `{ bands, lit }`. */
  doors(imp, side, height) {
    return JSON.parse(this.node.doors(imp, side, height));
  }

  /**
   * Uploads a file for a question to an Imp this page holds: `upload` and its parts go to `to` (the Imp's home),
   * and the id goes in the `ask`'s `attachments`. Null when it can't go (not connected, too large).
   */
  upload(imp, to, name, mime, bytes) {
    if (typeof this.node.upload !== 'function') throw new Error('This page needs rebuilding to send files.');
    return this.run((n) => n.upload(imp, to, name, mime, bytes, now())) ?? null;
  }

  sendHome(imp) {
    return this.run((n) => n.send_home(imp, now()));
  }

  setStage(stage) {
    this.run((n) => n.set_stage(JSON.stringify(stage)));
  }

  forget(device) {
    this.run((n) => n.forget(device, now()));
  }

  flush() {
    for (;;) {
      const outputs = JSON.parse(this.node.drain());
      if (!outputs.length) return;
      for (const output of outputs) this.carry(output);
    }
  }

  carry(output) {
    if (output.send) {
      const ws = this.sockets.get(output.send.conn);
      if (ws && ws.readyState === WebSocket.OPEN) ws.send(fromBase64(output.send.bytes));
    } else if (output.close) {
      const ws = this.sockets.get(output.close.conn);
      this.sockets.delete(output.close.conn);
      if (ws) ws.close();
    } else if (output.dial) {
      this.dial(output.dial);
    } else if (output.save !== undefined) {
      try {
        localStorage.setItem(BOOK, output.save);
      } catch (e) {
        this.node.save_failed(String(e));
      }
    } else if (output.hopChanged) {
      this.restartHost();
    } else if (output.event) {
      const [type] = Object.keys(output.event);
      this.emit(type, output.event[type]);
      this.emit('change', null);
    }
  }

  /**
   * Reads and writes a connection the node knows. Call it right after `dialed` or `accepted`, before
   * anything flushes the node: its first bytes for the connection are already waiting.
   */
  attach(conn, ws, rest) {
    this.sockets.set(conn, ws);
    ws.onmessage = (e) => this.run((n) => n.received(conn, new Uint8Array(e.data), now()));
    ws.onclose = () => {
      if (this.sockets.get(conn) === ws) {
        this.sockets.delete(conn);
        this.run((n) => n.closed(conn, now()));
      }
    };
    ws.onerror = () => ws.close();
    if (rest && rest.length) this.run((n) => n.received(conn, rest, now()));
    this.flush();
  }

  /** Tries the device itself on each of its addresses, then its Hop, as the apps do. */
  async dial(request) {
    const device = request.device;
    // A device's own port takes a WebSocket only when it serves one, and only from a page that isn't
    // https (a browser keeps an https page off ws:// addresses).
    if (location.protocol !== 'https:' && request.port && request.hosts.length) {
      // Every address at once, briefly: a device that takes WebSockets answers the upgrade at once.
      const tries = request.hosts.map((host) => openSocket(`ws://${host}:${request.port}/`, DIRECT_TIMEOUT));
      try {
        const ws = await Promise.any(tries);
        for (const t of tries) t.then((other) => { if (other !== ws) other.close(); }, () => {});
        const conn = this.node.dialed(device, false, now());
        if (conn === undefined) {
          ws.close();
          this.flush();
        } else this.attach(conn, ws);
        return;
      } catch {
        // None of them: the Hop next.
      }
    }
    const hop = this.node.hop_guest(device);
    if (hop) {
      try {
        const ws = await openSocket(hopSocketUrl(hop.address, this.options.hopSocket));
        const { status, rest } = await hopHandshake(ws, hop, GUEST_WAIT);
        hop.free();
        if (status === 'go') {
          const conn = this.node.dialed(device, true, now());
          if (conn === undefined) {
            ws.close();
            this.flush();
          } else this.attach(conn, ws, rest);
          return;
        }
        ws.close();
      } catch {
        // No Hop either.
      }
    }
    this.run((n) => n.dial_failed(device, now()));
  }

  /** Keeps one connection waiting at this device's Hop, for devices that scanned its code. */
  restartHost() {
    const generation = ++this.hostGeneration;
    if (this.hostWait) this.hostWait.close();
    this.hostWait = null;
    this.hostRetry = RETRY_FIRST;
    this.waitAtHop(generation);
  }

  async waitAtHop(generation) {
    while (generation === this.hostGeneration) {
      const hop = this.node.hop_host();
      if (!hop) return;
      let status = 'closed';
      let ws = null;
      let rest;
      try {
        ws = await openSocket(hopSocketUrl(hop.address, this.options.hopSocket));
        if (generation !== this.hostGeneration) {
          ws.close();
          return;
        }
        this.hostWait = ws;
        ({ status, rest } = await hopHandshake(ws, hop, 0));
      } catch {
        status = 'closed';
      }
      hop.free();
      if (generation !== this.hostGeneration) {
        if (ws) ws.close();
        return;
      }
      if (status === 'go') {
        this.hostRetry = RETRY_FIRST;
        const conn = this.node.accepted(true, now());
        if (conn === undefined) {
          ws.close();
          this.flush();
        } else this.attach(conn, ws, rest);
        continue; // Wait again at once for the next guest.
      }
      if (status === 'nobody') {
        this.hostRetry = RETRY_FIRST;
        continue;
      }
      if (status === 'rejected') {
        this.run((n) => n.hop_rejected());
        return;
      }
      this.emit('hop', { reachable: false });
      await new Promise((r) => setTimeout(r, this.hostRetry));
      this.hostRetry = Math.min(this.hostRetry * 2, RETRY_LONGEST);
    }
  }
}
