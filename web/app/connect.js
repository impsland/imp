// Connecting a device: one small sheet with a camera that reads the other device's code and a box to
// paste it in, as on the Mac. The code is `implink://join?...` (the Mac's Devices › Show code, the iPhone's,
// or `/pair` in the terminal app). Joining is the link's (`Link.join`). This only finds the code.

import * as wasm from './pkg/imp_web.js';

const $ = (id) => document.getElementById(id);
/** How often a frame is read, in milliseconds. */
const SCAN_EVERY = 180;
/** Frames are read at most this wide: plenty for a code that fills the middle of the camera. */
const SCAN_WIDTH = 640;
/** How long "Connected" stays before the sheet closes. */
const DONE_DELAY = 1400;
/**
 * How long a code that got no answer is tried again while the sheet is open, and how often. The other
 * device may be away for a moment: an iPhone whose link was copied into Safari is in the background, and
 * answers once Imp is open again.
 */
const RETRY_FOR = 3 * 60 * 1000;
const RETRY_EVERY = 2500;

const ICONS = {
  camera: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 8a2 2 0 0 1 2-2h2l2-2h6l2 2h2a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><circle cx="12" cy="13" r="3.5"/></svg>',
  done: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
};

/** The text of a linking code in what was read or pasted (a page link with `#join=` carries one too). */
export function findCode(text) {
  const trimmed = String(text || '').trim();
  const at = trimmed.indexOf('implink://');
  if (at < 0) return null;
  let code = trimmed.slice(at).split(/\s/)[0];
  try {
    code = decodeURIComponent(code);
  } catch {
    // Already plain.
  }
  return code;
}

export class ConnectSheet {
  /** `link` joins a device; the sheet hears its `joined` event. */
  constructor(link) {
    this.link = link;
    this.sheet = $('sheet');
    this.finder = $('finder');
    this.video = $('camera');
    this.note = $('finder-note');
    this.input = $('code');
    this.error = $('sheet-error');
    this.stream = null;
    this.timer = null;
    this.joining = null;
    this.detector = null;
    this.canvas = document.createElement('canvas');

    $('code-form').addEventListener('submit', (e) => {
      e.preventDefault();
      this.use(this.input.value);
    });
    // A pasted code connects at once.
    this.input.addEventListener('paste', () => setTimeout(() => {
      if (findCode(this.input.value)) this.use(this.input.value);
    }));
    this.input.addEventListener('input', () => { this.error.textContent = ''; });
    // A click on the dimmed page around the sheet closes it.
    this.sheet.addEventListener('click', (e) => { if (e.target === this.sheet) this.sheet.close(); });
    this.sheet.addEventListener('close', () => {
      this.stopCamera();
      clearTimeout(this.retry);
      this.joining = null;
    });
    link.addEventListener('joined', (e) => this.joined(e.detail));
  }

  open() {
    this.reset();
    if (!this.sheet.open) this.sheet.showModal();
    // On a phone the keyboard would cover the camera: the box takes focus only where there is a keyboard of its own.
    if (matchMedia('(hover: hover)').matches) this.input.focus();
    this.startCamera();
  }

  reset() {
    clearTimeout(this.retry);
    this.joining = null;
    this.input.value = '';
    this.error.textContent = '';
    this.finder.classList.remove('done', 'busy');
    this.showNote(ICONS.camera, '');
  }

  showNote(icon, text) {
    this.note.innerHTML = icon;
    if (text) this.note.append(Object.assign(document.createElement('span'), { textContent: text }));
  }

  // ---------------------------------------------------------------- the camera

  async startCamera() {
    if (this.stream) return;
    if (!navigator.mediaDevices?.getUserMedia) {
      // Only https pages (and localhost) may use the camera.
      this.showNote(ICONS.camera, 'Paste the code below');
      return;
    }
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
    } catch {
      this.showNote(ICONS.camera, 'Paste the code below');
      return;
    }
    if (!this.sheet.open) return this.stopCamera();
    const facing = this.stream.getVideoTracks()[0]?.getSettings().facingMode;
    // A camera that faces you is shown as a mirror, as a Mac shows its own.
    this.finder.style.setProperty('--mirror', facing === 'environment' ? '1' : '-1');
    this.video.srcObject = this.stream;
    await this.video.play().catch(() => {});
    this.finder.classList.add('live');
    this.detector = await makeDetector();
    this.timer = setInterval(() => this.scan(), SCAN_EVERY);
  }

  stopCamera() {
    clearInterval(this.timer);
    this.timer = null;
    for (const track of this.stream?.getTracks() || []) track.stop();
    this.stream = null;
    this.video.srcObject = null;
    this.finder.classList.remove('live');
  }

  async scan() {
    if (this.joining || this.scanning || this.video.readyState < 2) return;
    this.scanning = true;
    try {
      const text = await this.read();
      const code = findCode(text);
      // A code that just failed isn't tried again while it is still in front of the camera.
      if (code && !(code === this.failed?.code && Date.now() - this.failed.at < 4000)) this.use(code);
    } catch {
      // A frame that can't be read: the next one may.
    } finally {
      this.scanning = false;
    }
  }

  /** The text of the code in the camera's frame now, if any. */
  async read() {
    if (this.detector) {
      try {
        const found = await this.detector.detect(this.video);
        return found[0]?.rawValue || null;
      } catch {
        this.detector = null; // Fall back to the page's own reader.
      }
    }
    if (typeof wasm.scan_qr !== 'function' || !this.link.node) return null;
    const scale = Math.min(1, SCAN_WIDTH / this.video.videoWidth);
    const width = Math.round(this.video.videoWidth * scale);
    const height = Math.round(this.video.videoHeight * scale);
    if (!width || !height) return null;
    this.canvas.width = width;
    this.canvas.height = height;
    const context = this.canvas.getContext('2d', { willReadFrequently: true });
    context.drawImage(this.video, 0, 0, width, height);
    const frame = context.getImageData(0, 0, width, height);
    return wasm.scan_qr(new Uint8Array(frame.data.buffer), width, height) || null;
  }

  // ---------------------------------------------------------------- joining

  use(text) {
    const code = findCode(text);
    if (!code) {
      this.error.textContent = 'That is not a linking code.';
      return;
    }
    if (this.joining) return;
    this.lastCode = code;
    this.started = Date.now();
    try {
      this.joining = this.link.join(code);
    } catch (err) {
      this.error.textContent = String(err.message || err);
      return;
    }
    this.joining = this.joining || true;
    this.error.textContent = '';
    this.finder.classList.add('busy');
    this.note.innerHTML = '<div class="spinner"></div>';
  }

  joined({ ok, host, error }) {
    if (!this.joining) return;
    this.joining = null;
    // No answer yet: wait for the other device and try again, quietly, while the sheet is open.
    if (!ok && (error === 'TimedOut' || error === 'Unreachable') && this.sheet.open && Date.now() - this.started < RETRY_FOR) {
      this.joining = 'waiting';
      this.showNote('<div class="spinner"></div>', `Waiting for ${peerName(this.lastCode)}`);
      this.note.append(Object.assign(document.createElement('small'), { textContent: 'Open Imp on it' }));
      this.retry = setTimeout(() => {
        if (!this.sheet.open || this.joining !== 'waiting') return;
        try {
          this.joining = this.link.join(this.lastCode) || true;
        } catch (err) {
          this.joining = null;
          this.finder.classList.remove('busy');
          this.error.textContent = String(err.message || err);
        }
      }, RETRY_EVERY);
      return;
    }
    this.finder.classList.remove('busy');
    if (!ok) {
      this.failed = { code: this.lastCode, at: Date.now() };
      this.showNote(ICONS.camera, '');
      this.error.textContent = {
        Unreachable: 'The device could not be reached. Is it on, with a Hop?',
        Refused: 'The code was refused. Show a new one.',
        TimedOut: 'The device did not answer.',
      }[error] || 'Could not connect.';
      return;
    }
    this.stopCamera();
    this.finder.classList.add('done');
    this.showNote(ICONS.done, host?.name || 'Connected');
    setTimeout(() => { if (this.finder.classList.contains('done')) this.sheet.close(); }, DONE_DELAY);
  }
}

/** The name a code gives its device (`n`), for "Waiting for …". */
function peerName(code) {
  try {
    return new URLSearchParams(String(code).split('?')[1] || '').get('n') || 'the other device';
  } catch {
    return 'the other device';
  }
}

/** The browser's own code reader, when it has one that reads QR codes. */
async function makeDetector() {
  if (!('BarcodeDetector' in window)) return null;
  try {
    const formats = await window.BarcodeDetector.getSupportedFormats();
    return formats.includes('qr_code') ? new window.BarcodeDetector({ formats: ['qr_code'] }) : null;
  } catch {
    return null;
  }
}
