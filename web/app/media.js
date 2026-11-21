// Photos, sound and video sent to an Imp (docs/connecting/link.md, "Attachments"): the page prepares them
// (pictures scaled down, sound as WAV, which every model that hears takes), and the link uploads them to the
// Imp's home before the question that names them. Also the camera, where the Imps on the page can get in
// the way of the shot.

/** The most one file may weigh, and the most files one message carries (the engine's MAX_MEDIA_BYTES, MAX_ATTACHMENTS). */
export const MAX_BYTES = 25 * 1024 * 1024;
export const MAX_FILES = 4;
/** The longest side a picture is sent at, as on the Mac. */
const MAX_PIXELS = 2048;
/** Sound is sent as 16 kHz mono WAV: small, and read by every model that hears. */
const SOUND_RATE = 16000;
/** The longest recording. */
export const MAX_RECORDING = 120;

/** `image`, `audio`, `video` or `file`, from a MIME type. */
export function kindOf(mime) {
  const top = String(mime || '').split('/')[0];
  return ['image', 'audio', 'video'].includes(top) ? top : 'file';
}

/** What a message says when it is only a file. */
export function defaultWords(files) {
  const kinds = new Set(files.map((f) => f.kind));
  if (kinds.size === 1 && kinds.has('image')) return files.length > 1 ? 'Take a look at these photos.' : 'Take a look at this photo.';
  if (kinds.size === 1 && kinds.has('audio')) return 'Listen to this.';
  if (kinds.size === 1 && kinds.has('video')) return 'Watch this.';
  return 'Take a look at this.';
}

/** A file ready to send: `{ name, mime, kind, bytes, preview }` (`preview` an object URL, for pictures and video). */
async function attachment(name, blob) {
  const mime = blob.type || 'application/octet-stream';
  const bytes = new Uint8Array(await blob.arrayBuffer());
  if (bytes.length > MAX_BYTES) throw new Error(`${name} is too large to send (25 MB at most).`);
  const kind = kindOf(mime);
  return { name, mime, kind, bytes, preview: kind === 'image' || kind === 'video' ? URL.createObjectURL(blob) : null };
}

/** A file picked, dropped or pasted. Pictures are scaled to 2048 pixels on the long side. */
export async function fromFile(file) {
  if (kindOf(file.type) === 'image' && file.type !== 'image/gif') {
    const scaled = await scaledPicture(file).catch(() => null);
    if (scaled) return attachment(renamed(file.name || 'photo', scaled.type), scaled);
  }
  return attachment(file.name || `file.${(file.type.split('/')[1] || 'bin')}`, file);
}

/** A photo drawn on a canvas. */
export async function fromCanvas(canvas, name = 'photo.jpg') {
  const blob = await new Promise((done) => canvas.toBlob(done, 'image/jpeg', 0.88));
  return attachment(name, blob);
}

function renamed(name, mime) {
  const ext = mime === 'image/png' ? 'png' : 'jpg';
  return name.replace(/\.[^.]+$/, '') + '.' + ext;
}

async function scaledPicture(file) {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, MAX_PIXELS / Math.max(bitmap.width, bitmap.height));
  if (scale === 1 && file.size < 2 * 1024 * 1024 && /png|jpeg/.test(file.type)) return file;
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close?.();
  // JPEG keeps photos small. A PNG that may have transparency stays PNG.
  const mime = file.type === 'image/png' && file.size < 4 * 1024 * 1024 ? 'image/png' : 'image/jpeg';
  return new Promise((done) => canvas.toBlob(done, mime, 0.88));
}

// ---------------------------------------------------------------- sound

/** 16-bit PCM WAV of mono samples (-1 to 1) at `rate`. */
export function wav(samples, rate) {
  const data = new DataView(new ArrayBuffer(44 + samples.length * 2));
  const text = (at, s) => [...s].forEach((c, i) => data.setUint8(at + i, c.charCodeAt(0)));
  text(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, true);
  text(8, 'WAVE');
  text(12, 'fmt ');
  data.setUint32(16, 16, true);
  data.setUint16(20, 1, true); // PCM
  data.setUint16(22, 1, true); // mono
  data.setUint32(24, rate, true);
  data.setUint32(28, rate * 2, true);
  data.setUint16(32, 2, true);
  data.setUint16(34, 16, true);
  text(36, 'data');
  data.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    data.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return new Blob([data], { type: 'audio/wav' });
}

/** Any sound the browser can play, as 16 kHz mono WAV. */
export async function toWav(blob) {
  const raw = await blob.arrayBuffer();
  const decoded = await new AudioContext().decodeAudioData(raw);
  const frames = Math.max(1, Math.ceil(decoded.duration * SOUND_RATE));
  const offline = new OfflineAudioContext(1, frames, SOUND_RATE);
  const source = offline.createBufferSource();
  source.buffer = decoded;
  source.connect(offline.destination);
  source.start();
  const mixed = await offline.startRendering();
  return wav(mixed.getChannelData(0), SOUND_RATE);
}

/**
 * Records from the microphone. `level()` is how loud it is now (0 to 1), for a meter. `stop()` gives the
 * recording as a WAV attachment, `cancel()` drops it.
 */
export class Recorder {
  static async start() {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    return new Recorder(stream);
  }

  constructor(stream) {
    this.stream = stream;
    this.chunks = [];
    this.started = performance.now();
    this.recorder = new MediaRecorder(stream);
    this.recorder.ondataavailable = (e) => { if (e.data.size) this.chunks.push(e.data); };
    this.recorder.start(250);
    this.context = new AudioContext();
    this.analyser = this.context.createAnalyser();
    this.analyser.fftSize = 256;
    this.context.createMediaStreamSource(stream).connect(this.analyser);
    this.samples = new Uint8Array(this.analyser.fftSize);
  }

  get seconds() {
    return (performance.now() - this.started) / 1000;
  }

  level() {
    this.analyser.getByteTimeDomainData(this.samples);
    let peak = 0;
    for (const v of this.samples) peak = Math.max(peak, Math.abs(v - 128));
    return Math.min(1, peak / 90);
  }

  async stop() {
    const done = new Promise((resolve) => { this.recorder.onstop = resolve; });
    this.recorder.stop();
    await done;
    this.release();
    const recorded = new Blob(this.chunks, { type: this.recorder.mimeType || 'audio/webm' });
    const sound = await toWav(recorded);
    const stamp = new Date().toTimeString().slice(0, 8).replaceAll(':', '-');
    return attachment(`recording-${stamp}.wav`, sound);
  }

  cancel() {
    try { this.recorder.stop(); } catch { /* already stopped */ }
    this.release();
  }

  release() {
    for (const track of this.stream.getTracks()) track.stop();
    this.context.close().catch(() => {});
  }
}

// ---------------------------------------------------------------- the camera

/**
 * The camera, full screen under the Imps on the page: they stay where they are, can be carried over the
 * picture, and are in the photo where they stand. `shoot(imps)` draws the frame as seen, Imps and all.
 */
export class Camera {
  constructor(layer, video) {
    this.layer = layer;
    this.video = video;
    this.stream = null;
    this.facing = 'environment';
  }

  async open() {
    await this.start();
    this.layer.hidden = false;
    requestAnimationFrame(() => this.layer.classList.add('shown'));
  }

  async start() {
    this.stopStream();
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: { ideal: this.facing }, width: { ideal: 1920 }, height: { ideal: 1080 } },
      audio: false,
    });
    const facing = this.stream.getVideoTracks()[0]?.getSettings().facingMode;
    // A camera that faces you is shown as a mirror, and the photo is taken as you saw it.
    this.mirrored = facing !== 'environment';
    this.layer.style.setProperty('--mirror', this.mirrored ? '-1' : '1');
    this.video.srcObject = this.stream;
    await this.video.play().catch(() => {});
  }

  /** The other camera, where there is one. */
  async flip() {
    this.facing = this.facing === 'environment' ? 'user' : 'environment';
    await this.start().catch(() => {});
  }

  close() {
    this.stopStream();
    this.layer.classList.remove('shown');
    this.layer.hidden = true;
  }

  stopStream() {
    for (const track of this.stream?.getTracks() || []) track.stop();
    this.stream = null;
    this.video.srcObject = null;
  }

  /** The picture as it is on screen: the camera's frame cropped as shown, with each Imp drawn where it is. */
  async shoot(imps) {
    const scale = Math.min(2, devicePixelRatio || 1);
    const width = innerWidth;
    const height = innerHeight;
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(width * scale);
    canvas.height = Math.round(height * scale);
    const g = canvas.getContext('2d');
    g.scale(scale, scale);
    // The video fills the screen as `object-fit: cover` shows it.
    const vw = this.video.videoWidth || width;
    const vh = this.video.videoHeight || height;
    const cover = Math.max(width / vw, height / vh);
    const dw = vw * cover;
    const dh = vh * cover;
    g.save();
    if (this.mirrored) {
      g.translate(width, 0);
      g.scale(-1, 1);
    }
    g.drawImage(this.video, (width - dw) / 2, (height - dh) / 2, dw, dh);
    g.restore();
    for (const imp of imps) {
      const svg = imp.querySelector('svg');
      const box = imp.getBoundingClientRect();
      if (!svg || box.right < 0 || box.left > width || box.bottom < 0 || box.top > height) continue;
      const picture = await svgImage(svg, box.width, box.height).catch(() => null);
      if (picture) g.drawImage(picture, box.left, box.top, box.width, box.height);
    }
    return canvas;
  }
}

/** An SVG on the page as an image, at the size it is shown. */
function svgImage(svg, width, height) {
  const copy = svg.cloneNode(true);
  copy.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
  copy.setAttribute('width', String(width));
  copy.setAttribute('height', String(height));
  const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(copy)], { type: 'image/svg+xml' }));
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => { URL.revokeObjectURL(url); resolve(image); };
    image.onerror = (e) => { URL.revokeObjectURL(url); reject(e); };
    image.src = url;
  });
}
