/**
 * topaz.js — Topaz Signature Pad Library
 * Connects to Topaz USB signature pads via Web Serial API (Chrome/Edge).
 *
 * @example
 * import { TopazPad } from 'topaz-dext';
 *
 * const pad = new TopazPad();
 * pad.on('stroke', stroke => console.log(stroke));
 * await pad.connect();
 */

// -- Models --

export const MODELS = {
  SignatureGem1X5:    { xStart:400, xStop:2400, yStart:350, yStop:950,  logicalX:2000, logicalY:600,  baud:19200, filter:4, fmt:0 },
  SignatureGemLCD1X5: { xStart:400, xStop:2400, yStart:350, yStop:1250, logicalX:2000, logicalY:900,  baud:19200, filter:4, fmt:1 },
  SignatureGem4X5:    { xStart:500, xStop:2650, yStart:700, yStop:2100, logicalX:2150, logicalY:1400, baud:19200, filter:4, fmt:0 },
  SigLite1X5:         { xStart:500, xStop:2650, yStart:700, yStop:2100, logicalX:2150, logicalY:1400, baud:19200, filter:2, fmt:0 },
  SigLiteLCD1X5:      { xStart:400, xStop:2400, yStart:350, yStop:1050, logicalX:2000, logicalY:700,  baud:19200, filter:4, fmt:0 },
  SigLiteLCD4X5:      { xStart:500, xStop:2600, yStart:500, yStop:2100, logicalX:2100, logicalY:1600, baud:38400, filter:4, fmt:0 },
  ClipGem:            { xStart:485, xStop:2800, yStart:170, yStop:3200, logicalX:2315, logicalY:3030, baud:9600,  filter:2, fmt:0 },
  SigGemColor57:      { xStart:300, xStop:2370, yStart:350, yStop:1950, logicalX:2070, logicalY:1600, baud:115200, filter:4, fmt:0 },
};

// -- 1-Euro Filter (Casiez et al., CHI 2012) --

export class OneEuroFilter {
  constructor(mincutoff = 1.0, beta = 0.007, dcutoff = 1.0) {
    this.mincutoff = mincutoff;
    this.beta = beta;
    this.dcutoff = dcutoff;
    this.xPrev = 0; this.dxPrev = 0;
    this.yPrev = 0; this.dyPrev = 0;
    this.tPrev = 0; this.initialized = false;
  }

  static fromLevel(level) {
    const presets = [
      [100, 0, 1],       // 0: off
      [1.5, 0.01, 1],    // 1: light
      [0.8, 0.005, 1],   // 2: medium
      [0.3, 0.002, 1],   // 3: heavy
    ];
    const [mc, b, dc] = presets[Math.min(level, 3)];
    return new OneEuroFilter(mc, b, dc);
  }

  _alpha(cutoff, dt) {
    const tau = 1.0 / (2 * Math.PI * cutoff);
    return 1.0 / (1.0 + tau / dt);
  }

  filter(x, y, timestamp) {
    if (!this.initialized) {
      this.xPrev = x; this.yPrev = y; this.tPrev = timestamp;
      this.initialized = true;
      return { x, y };
    }
    const dt = Math.max(0.001, timestamp - this.tPrev);
    this.tPrev = timestamp;

    const dx = (x - this.xPrev) / dt, dy = (y - this.yPrev) / dt;
    const aD = this._alpha(this.dcutoff, dt);
    const fdx = aD * dx + (1 - aD) * this.dxPrev;
    const fdy = aD * dy + (1 - aD) * this.dyPrev;
    this.dxPrev = fdx; this.dyPrev = fdy;

    const speed = Math.sqrt(fdx * fdx + fdy * fdy);
    const cutoff = this.mincutoff + this.beta * speed;
    const a = this._alpha(cutoff, dt);

    const fx = a * x + (1 - a) * this.xPrev;
    const fy = a * y + (1 - a) * this.yPrev;
    this.xPrev = fx; this.yPrev = fy;
    return { x: fx, y: fy };
  }

  reset() { this.initialized = false; this.dxPrev = 0; this.dyPrev = 0; }
}

// -- Stabilization (legacy post-process) --

export function rdpSimplify(pts, epsilon) {
  if (pts.length <= 2) return pts;
  let maxDist = 0, maxIdx = 0;
  const a = pts[0], b = pts[pts.length - 1];
  const dx = b.x - a.x, dy = b.y - a.y, lenSq = dx * dx + dy * dy;
  for (let i = 1; i < pts.length - 1; i++) {
    let d;
    if (lenSq < 1e-10) {
      const ex = pts[i].x - a.x, ey = pts[i].y - a.y;
      d = Math.sqrt(ex * ex + ey * ey);
    } else {
      const t = Math.max(0, Math.min(1, ((pts[i].x - a.x) * dx + (pts[i].y - a.y) * dy) / lenSq));
      const ex = pts[i].x - (a.x + t * dx), ey = pts[i].y - (a.y + t * dy);
      d = Math.sqrt(ex * ex + ey * ey);
    }
    if (d > maxDist) { maxDist = d; maxIdx = i; }
  }
  if (maxDist > epsilon) {
    const left = rdpSimplify(pts.slice(0, maxIdx + 1), epsilon);
    const right = rdpSimplify(pts.slice(maxIdx), epsilon);
    return left.slice(0, -1).concat(right);
  }
  return [pts[0], pts[pts.length - 1]];
}

export function stabilize(pts, level = 1) {
  if (level <= 0 || pts.length < 3) return pts;
  let points = pts;
  if (level >= 2) points = rdpSimplify(points, level * 0.5);
  const tension = Math.min(1.0, level * 0.5);
  const result = [points[0]];
  for (let i = 0; i < points.length - 1; i++) {
    const p0 = points[Math.max(0, i - 1)];
    const p1 = points[i];
    const p2 = points[Math.min(points.length - 1, i + 1)];
    const p3 = points[Math.min(points.length - 1, i + 2)];
    const dx = p2.x - p1.x, dy = p2.y - p1.y;
    const steps = Math.max(2, Math.floor(Math.sqrt(dx * dx + dy * dy) / 3));
    for (let s = 1; s <= steps; s++) {
      const t = s / steps, t2 = t * t, t3 = t2 * t;
      result.push({
        x: 0.5 * ((2*p1.x) + (-p0.x+p2.x)*t*tension + (2*p0.x-5*p1.x+4*p2.x-p3.x)*t2*tension + (-p0.x+3*p1.x-3*p2.x+p3.x)*t3*tension),
        y: 0.5 * ((2*p1.y) + (-p0.y+p2.y)*t*tension + (2*p0.y-5*p1.y+4*p2.y-p3.y)*t2*tension + (-p0.y+3*p1.y-3*p2.y+p3.y)*t3*tension),
        p: p1.p,
      });
    }
  }
  return result;
}

// -- Export --

export function strokesBounds(strokes, inkWidth = 3) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const s of strokes) {
    for (const p of s) {
      if (p.x < minX) minX = p.x; if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x; if (p.y > maxY) maxY = p.y;
    }
  }
  const pad = inkWidth * 2;
  return { minX: minX - pad, minY: minY - pad, maxX: maxX + pad, maxY: maxY + pad };
}

export function toSVG(strokes, { inkColor = '#000000', inkWidth = 3, padding = 10 } = {}) {
  const b = strokesBounds(strokes, inkWidth);
  const w = Math.ceil(b.maxX - b.minX + padding * 2);
  const h = Math.ceil(b.maxY - b.minY + padding * 2);
  let svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}">`;
  for (const stroke of strokes) {
    if (stroke.length < 2) continue;
    const pts = stroke.map(p =>
      `${(p.x - b.minX + padding).toFixed(1)},${(p.y - b.minY + padding).toFixed(1)}`
    ).join(' ');
    svg += `\n  <polyline points="${pts}" fill="none" stroke="${inkColor}" stroke-width="${inkWidth}" stroke-linecap="round" stroke-linejoin="round"/>`;
  }
  svg += '\n</svg>';
  return svg;
}

export function toCanvas(strokes, { inkColor = '#000000', inkWidth = 3, padding = 10, scale = 2 } = {}) {
  const b = strokesBounds(strokes, inkWidth);
  const pad = inkWidth * 2 + padding;
  const cw = Math.ceil((b.maxX - b.minX + pad * 2) * scale);
  const ch = Math.ceil((b.maxY - b.minY + pad * 2) * scale);
  const canvas = document.createElement('canvas');
  canvas.width = cw; canvas.height = ch;
  const ctx = canvas.getContext('2d');
  ctx.strokeStyle = inkColor;
  ctx.lineWidth = inkWidth * scale;
  ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  for (const stroke of strokes) {
    if (stroke.length < 2) continue;
    ctx.beginPath();
    ctx.moveTo((stroke[0].x - b.minX + pad) * scale, (stroke[0].y - b.minY + pad) * scale);
    for (let i = 1; i < stroke.length; i++) {
      ctx.lineTo((stroke[i].x - b.minX + pad) * scale, (stroke[i].y - b.minY + pad) * scale);
    }
    ctx.stroke();
  }
  return canvas;
}

export async function toPNG(strokes, opts = {}) {
  const canvas = toCanvas(strokes, opts);
  return new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
}

export function toSigString(strokes) {
  let total = 0;
  for (const s of strokes) total += s.length;
  const lines = [String(total), String(strokes.length)];
  for (const stroke of strokes) {
    for (const p of stroke) lines.push(`${Math.round(p.x)} ${Math.round(p.y)}`);
  }
  let cumulative = 0;
  for (const stroke of strokes) {
    cumulative += stroke.length - 1;
    lines.push(String(cumulative));
  }
  const raw = lines.join('\r\n');
  return Array.from(new TextEncoder().encode(raw), b => b.toString(16).padStart(2, '0').toUpperCase()).join('');
}

// -- Main Class --

export class TopazPad {
  constructor(model = 'SignatureGem1X5', { stabilize = 1 } = {}) {
    this.model = MODELS[model] || MODELS.SignatureGem1X5;
    this.modelName = model;
    this.port = null;
    this.reader = null;
    this.reading = false;
    this.strokes = [];
    this.currentStroke = [];
    this.penDown = false;
    this.penNear = false;
    this.pressure = 0;
    this.totalPoints = 0;
    this._listeners = {};
    this._packetState = 0;
    this._packetBuf = [];
    this._filterX = [];
    this._filterY = [];
    this._euroFilter = OneEuroFilter.fromLevel(stabilize);
    this._lastPenActivity = 0;
    this._lastProximityLost = 0;
    this._penLeftProximity = false;
    this._completionTimer = null;
  }

  // -- Events --

  on(event, fn) {
    (this._listeners[event] = this._listeners[event] || []).push(fn);
    return this;
  }

  off(event, fn) {
    const l = this._listeners[event];
    if (l) this._listeners[event] = l.filter(f => f !== fn);
    return this;
  }

  _emit(event, ...args) {
    for (const fn of this._listeners[event] || []) fn(...args);
  }

  // -- Connection --

  get connected() { return this.port !== null && this.reading; }

  async connect(existingPort = null) {
    if (!navigator.serial) throw new Error('Web Serial API not supported');
    this.port = existingPort || await navigator.serial.requestPort({
      filters: [{ usbVendorId: 0x0403 }],
    });
    await this.port.open({
      baudRate: this.model.baud,
      dataBits: this.model.fmt === 1 ? 7 : 8,
      parity: 'odd',
      stopBits: 1,
      bufferSize: 4096,
    });
    this.reading = true;
    this._emit('connect');
    this._readLoop();
  }

  async disconnect() {
    this.reading = false;
    try {
      if (this.reader) { await this.reader.cancel(); this.reader.releaseLock(); this.reader = null; }
      if (this.port) { await this.port.close(); }
    } catch (e) {}
    this.port = null;
    this._emit('disconnect');
  }

  clear() {
    this.strokes = [];
    this.currentStroke = [];
    this.penDown = false;
    this.totalPoints = 0;
    this._filterX = [];
    this._filterY = [];
    this._emit('clear');
  }

  // -- Internal --

  async _readLoop() {
    while (this.port && this.port.readable && this.reading) {
      this.reader = this.port.readable.getReader();
      try {
        while (this.reading) {
          const { value, done } = await this.reader.read();
          if (done) break;
          this._processBytes(value);
        }
      } catch (e) {
        if (this.reading) this._emit('error', e);
      } finally {
        try { this.reader.releaseLock(); } catch (e) {}
        this.reader = null;
      }
    }
    if (this.reading) await this.disconnect();
  }

  _processBytes(data) {
    const fmt = this.model.fmt;
    for (const byte of data) {
      const start = fmt === 0 ? (byte & 0x80) !== 0 : (byte & 0x70) !== 0x30;
      switch (this._packetState) {
        case 0:
          if (start) { this._packetBuf = [byte]; this._packetState = 1; }
          break;
        case 1:
          if (start) { this._packetBuf = [byte]; }
          else { this._packetBuf.push(byte); this._packetState = 2; }
          break;
        case 2:
          if (start) { this._packetBuf = [byte]; this._packetState = 1; }
          else {
            this._packetBuf.push(byte);
            if (this._packetBuf.length === 5) {
              const bad = fmt === 0 && this._packetBuf.slice(1).some(b => b & 0x80);
              if (!bad) this._decodePacket(this._packetBuf, fmt);
              this._packetBuf = [];
              this._packetState = 0;
            }
          }
          break;
      }
    }
  }

  _decodePacket(buf, fmt) {
    const status = buf[0];
    const down = (status & 0x01) !== 0;
    const type = (status >> 2) & 7;

    let rawX, rawY;
    if (fmt === 0) {
      rawX = ((buf[2] & 0x1F) << 7) | (buf[1] & 0x7F);
      rawY = ((buf[4] & 0x1F) << 7) | (buf[3] & 0x7F);
    } else {
      rawX = ((buf[2] & 0x3F) << 6) | (buf[1] & 0x3F);
      rawY = ((buf[4] & 0x3F) << 6) | (buf[3] & 0x3F);
    }

    if (rawX === 0x0FFF && rawY === 0x0FFF) return;

    if (type === 7) {
      this.pressure = ((buf[4] & 0x07) << 7) | (buf[3] & 0x7F);
      this._emit('pressure', this.pressure);
      return;
    }

    if (type === 2) {
      const d0 = (buf[1] & 0x7F) | ((buf[2] & 0x7F) << 7);
      const d1 = (buf[3] & 0x7F) | ((buf[4] & 0x7F) << 7);
      this._emit('info', { model: (d0 & 0xFC) >> 2, serial: ((d0 & 0x03) << 16) | d1 });
      return;
    }

    if (type !== 0 && type !== 1 && type !== 4) return;

    const near = fmt === 0 ? (status & 0x40) !== 0 : (status & 0x04) !== 0;
    const now = performance.now() / 1000;

    // Proximity tracking for smart completion
    if (down || near) {
      this._lastPenActivity = now;
      this._penLeftProximity = false;
      this.penNear = true;
    }
    if (!near && !down && !this._penLeftProximity) {
      this._penLeftProximity = true;
      this._lastProximityLost = now;
      this.penNear = false;
    }

    const m = this.model;
    let x = (rawX - m.xStart) * m.logicalX / (m.xStop - m.xStart);
    let y = (rawY - m.yStart) * m.logicalY / (m.yStop - m.yStart);
    x = Math.max(0, Math.min(m.logicalX, x));
    y = Math.max(0, Math.min(m.logicalY, y));

    // 1-Euro filter for stabilization
    const filtered = this._euroFilter.filter(x, y, now);

    const point = { x: filtered.x, y: filtered.y, p: this.pressure };

    if (down) {
      this._resetCompletionTimer();
      if (!this.penDown) {
        this.currentStroke = [point];
        this.penDown = true;
        this._emit('pendown', point);
      } else {
        this.currentStroke.push(point);
        this._emit('point', point);
      }
      this.totalPoints++;
    } else if (this.penDown) {
      if (this.currentStroke.length >= 2) {
        this.strokes.push(this.currentStroke);
        this._emit('stroke', this.currentStroke);
      }
      this.currentStroke = [];
      this.penDown = false;
      this._euroFilter.reset();
      this._emit('penup');
      this._startCompletionTimer();
    }
  }

  _startCompletionTimer() {
    this._resetCompletionTimer();
    if (this.totalPoints < 5) return;
    // Check periodically: proximity lost → 0.5s, inter-stroke → 1.5s, fallback → 3s
    this._completionTimer = setInterval(() => {
      if (this.penDown) return;
      const now = performance.now() / 1000;
      const sincePen = now - this._lastPenActivity;
      const sinceProx = now - this._lastProximityLost;
      if ((this._penLeftProximity && sinceProx > 0.5) || sincePen > 1.5) {
        this._resetCompletionTimer();
        this._emit('complete', this.strokes);
      }
    }, 100);
  }

  _resetCompletionTimer() {
    if (this._completionTimer) { clearInterval(this._completionTimer); this._completionTimer = null; }
  }

  // -- Export convenience methods --

  toSVG(opts) { return toSVG(this.strokes, opts); }
  toCanvas(opts) { return toCanvas(this.strokes, opts); }
  toPNG(opts) { return toPNG(this.strokes, opts); }
  toSigString() { return toSigString(this.strokes); }
}
