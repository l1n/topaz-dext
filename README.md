# Topaz Signature Pad Driver for macOS

Native macOS driver and capture tool for [Topaz Systems](https://www.topazsystems.com/) USB signature pads. No official drivers needed — connects directly via the reverse-engineered serial protocol.

**[Try the web version](https://l1n.github.io/topaz-dext/)** (Chrome/Edge/Firefox with [Web Serial addon](https://addons.mozilla.org/en-US/firefox/addon/webserial-for-firefox/))

## Features

- **~300KB native arm64 binary**, zero dependencies, single Swift file
- **Menu bar app** with auto-capture daemon (no dock icon, no terminal)
- **CLI** for scripted capture, format conversion, comparison
- **Auto-crop** with transparent background — paste directly into documents
- **Stroke stabilization** via [1-Euro adaptive filter](https://gery.casiez.net/1euro/) (Casiez et al., CHI 2012)
- **Smart completion** — pen proximity detection, not a fixed timeout
- **Export**: PNG, SVG, PDF, JPEG, TIFF, BMP, JSON, SigString
- **Clipboard** integration — signatures copied automatically
- **Biometric data** capture (velocity, acceleration, pressure, timing)
- **8 pad models** supported with automatic baud/format detection
- **LaunchAgent** for auto-start on login
- **Web version** — single HTML file using Web Serial API

## Supported Models

| Model | Baud | Format | Resolution |
|-------|------|--------|------------|
| SignatureGem 1x5 | 19200 | 8O1 | 410 dpi |
| SignatureGem LCD 1x5 | 19200 | 7O1 | 410 dpi |
| SignatureGem 4x5 | 19200 | 8O1 | 410 dpi |
| SigLite 1x5 | 19200 | 8O1 | 410 dpi |
| SigLite LCD 1x5 | 19200 | 8O1 | 410 dpi |
| SigLite LCD 4x5 | 38400 | 8O1 | 410 dpi |
| ClipGem | 9600 | 8O1 | 275 dpi |
| SigGem Color 5x7 | 115200 | 8O1 | 410 dpi |

Tested with the **T-LBK462-BSB-R** (SigLite 1x5), which uses an FTDI FT232R USB-to-serial bridge (VID `0x0403`, PID `0x6001`).

## Install

```bash
# Build from source
make
make install    # installs to ~/.local/bin/topaz + /Applications/Topaz.app

# Or download a release
# https://github.com/l1n/topaz-dext/releases
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## Usage

```bash
# Launch menu bar app (double-click Topaz.app or:)
topaz

# Capture a signature
topaz capture

# Capture with stabilization
topaz capture --stabilize 2

# Blue ink, heavy smoothing
topaz capture --ink-color '#000088' --stabilize 3

# Auto-start on login
topaz daemon install

# Test pad connectivity
topaz test

# Convert formats
topaz convert signature.json signature.pdf

# Compare two signatures (terminal braille rendering)
topaz compare sig1.svg sig2.svg --overlay
```

## Protocol

The Topaz serial protocol was reverse-engineered by decompiling the [SigPlus Java SDK](https://www.topazsystems.com/sdks/sigpluspro-java.html) v2.68 (`TabletInterface.java`).

### Physical Layer

Topaz BSB-model pads use an **FTDI FT232R** USB-to-serial bridge. The pad's microcontroller communicates over UART through this bridge, which presents as a virtual COM port to the OS:

- macOS: `/dev/cu.usbserial-TOPAZBSB`
- Linux: `/dev/ttyUSB0`
- Windows: `COMx`

### Serial Parameters

| Parameter | Value |
|-----------|-------|
| Baud rate | Model-dependent (9600–115200, typically **19200**) |
| Data bits | **8** (format 0) or **7** (format 1, LCD models) |
| Parity | **Odd** |
| Stop bits | **1** |
| Flow control | None |

The parity setting is critical — all public documentation says 8N1, but the actual protocol uses **odd parity**. This was the key discovery that made communication work.

### Packet Format

The pad streams 5-byte packets continuously while the pen is in proximity. No initialization sequence is required — the pad begins transmitting as soon as the serial port is opened with correct parameters.

```
Byte 0: Status byte (sync marker — bit 7 is always set)
Byte 1: X coordinate LSB
Byte 2: X coordinate MSB
Byte 3: Y coordinate LSB
Byte 4: Y coordinate MSB
```

Data bytes (1–4) always have bit 7 **clear** in format 0. This allows the receiver to synchronize — any byte with bit 7 set is the start of a new packet.

### Status Byte (Byte 0)

```
Bit 7:   1 (always set — sync marker)
Bit 6:   Pen near/proximity (format 0)
Bits 4-5: Reserved
Bits 2-3: Packet type
Bit 1:   Reserved
Bit 0:   Pen down (touching surface)
```

### Packet Types (`(status >> 2) & 7`)

| Type | Content |
|------|---------|
| 0, 1, 4 | **Pen position data** — X/Y coordinates |
| 7 | **Pressure data** — pressure value in Y fields |
| 2 | **Device info** — model number and serial number |
| 3 | **Command response** |
| 5, 6 | Reserved |

### Coordinate Decoding

**Format 0** (most models — 8-bit data):

```
X = ((byte2 & 0x1F) << 7) | (byte1 & 0x7F)    → 12-bit value (0–4095)
Y = ((byte4 & 0x1F) << 7) | (byte3 & 0x7F)    → 12-bit value (0–4095)
```

**Format 1** (some LCD models — 7-bit data):

```
X = ((byte2 & 0x3F) << 6) | (byte1 & 0x3F)    → 12-bit value
Y = ((byte4 & 0x3F) << 6) | (byte3 & 0x3F)    → 12-bit value
```

Raw coordinates are in the pad's hardware coordinate space (typically 410 dpi). Map to logical coordinates using the model's calibration range:

```
logicalX = (rawX - xStart) * logicalWidth / (xStop - xStart)
logicalY = (rawY - yStart) * logicalHeight / (yStop - yStart)
```

### Pressure Decoding (Type 7 Packets)

```
pressure = ((byte4 & 0x07) << 7) | (byte3 & 0x7F)    → 10-bit value (0–1023)
```

Pressure packets are interleaved with position packets. The last received pressure value applies to subsequent position packets.

### Device Info Decoding (Type 2 Packets)

```
data0 = (byte1 & 0x7F) | ((byte2 & 0x7F) << 7)
data1 = (byte3 & 0x7F) | ((byte4 & 0x7F) << 7)

modelNumber  = (data0 & 0xFC) >> 2      → 6-bit model ID
serialNumber = ((data0 & 0x03) << 16) | data1   → 18-bit serial
```

### Bad Packet Detection

A packet is invalid if:
- Any data byte (1–4) has bit 7 set (format 0 only)
- Both X and Y decode to `0x0FFF` (all ones — rejected as noise)

### State Machine

Packet synchronization uses a 3-state machine:

```
State 0 (Idle):     Wait for byte with bit 7 set → State 1
State 1 (Got sync): If next byte also has bit 7, restart. Otherwise → State 2
State 2 (Collecting): Collect bytes until 5 total. If bit 7 seen, restart at State 1
```

### Model Calibration Parameters

Each model has a hardware coordinate range that maps to the active digitizer area:

| Model | X range | Y range | Logical size |
|-------|---------|---------|--------------|
| SignatureGem 1x5 | 400–2400 | 350–950 | 2000×600 |
| SignatureGem LCD 1x5 | 400–2400 | 350–1250 | 2000×900 |
| SignatureGem 4x5 | 500–2650 | 700–2100 | 2150×1400 |
| SigLite 1x5 | 500–2650 | 700–2100 | 2150×1400 |
| SigLite LCD 1x5 | 400–2400 | 350–1050 | 2000×700 |
| SigLite LCD 4x5 | 500–2600 | 500–2100 | 2100×1600 |
| ClipGem | 485–2800 | 170–3200 | 2315×3030 |

### LCD Control Characters (Sent to Pad)

For models with LCD displays, single control characters switch capture modes:

| Byte | Function |
|------|----------|
| `0x04` (Ctrl-D) | Clear tablet, enable autoerase capture |
| `0x14` (Ctrl-T) | Persistent ink capture (no auto-clear) |
| `0x09` (Ctrl-I) | Inverted ink display |

### SigString Format

The SigString is the standard Topaz interchange format for signature data, used by SigPlus/SigWeb. It is a hex-encoded ASCII payload:

```
hex_decode(sigstring) →

Line 1: total_point_count
Line 2: total_stroke_count
Lines 3..N: "X Y" coordinate pairs (logical tablet coordinates)
Lines N+1..M: stroke endpoint indices (cumulative)
```

Lines are delimited by `\r\n`. Stroke endpoints indicate where each pen-up occurs — the value is an index into the coordinate array.

## JavaScript Library

Use the Topaz protocol directly from your web app via CDN:

```html
<script type="module">
import { TopazPad, toSVG, stabilize } from 'https://l1n.github.io/topaz-dext/lib/topaz.js';

const pad = new TopazPad('SignatureGem1X5');

// Events
pad.on('connect', () => console.log('Connected'));
pad.on('point', pt => console.log(`x=${pt.x} y=${pt.y} pressure=${pt.p}`));
pad.on('stroke', stroke => console.log(`Stroke: ${stroke.length} points`));
pad.on('pendown', () => console.log('Pen down'));
pad.on('penup', () => console.log('Pen up'));

// Connect (must be called from a user gesture)
document.getElementById('btn').onclick = () => pad.connect();

// After capturing, export:
const svg = pad.toSVG({ inkColor: '#000080', inkWidth: 2 });
const png = await pad.toPNG({ scale: 3 });
const sigString = pad.toSigString();

// Stabilize strokes
const smoothed = pad.strokes.map(s => stabilize(s, 2));
</script>
```

TypeScript definitions are included — use with your IDE or bundler:

```typescript
import { TopazPad, type Stroke, type Point } from 'https://l1n.github.io/topaz-dext/lib/topaz.js';
// or copy lib/topaz.js + lib/topaz.d.ts into your project
```

### API

| Export | Description |
|--------|-------------|
| `TopazPad(model?)` | Main class. Events: `connect`, `disconnect`, `pendown`, `penup`, `point`, `stroke`, `pressure`, `info`, `error` |
| `toSVG(strokes, opts?)` | Render strokes to SVG string (auto-cropped, transparent) |
| `toCanvas(strokes, opts?)` | Render to an offscreen `<canvas>` element |
| `toPNG(strokes, opts?)` | Render to PNG `Blob` |
| `toSigString(strokes)` | Export to Topaz SigString interchange format |
| `stabilize(points, level)` | Catmull-Rom spline smoothing (level 0-3) |
| `rdpSimplify(points, epsilon)` | Ramer-Douglas-Peucker simplification |
| `strokesBounds(strokes)` | Compute bounding box |
| `MODELS` | Model configuration database |

Requires Web Serial API (Chrome 89+ / Edge 89+). Firefox is supported via the [Web Serial for Firefox](https://addons.mozilla.org/en-US/firefox/addon/webserial-for-firefox/) addon. See [browser support](https://caniuse.com/web-serial).

## Swift Library (TopazKit)

Drop [`lib/TopazKit.swift`](lib/TopazKit.swift) into your Xcode project or compile alongside your Swift code. No frameworks beyond Foundation and Darwin.

```swift
import Foundation
// Add lib/TopazKit.swift to your target

// Auto-detect and connect
let pad = try TopazKit.open()

// Blocking capture (returns when pen idle for 10s)
if let sig = pad.capture(timeout: 10) {
    let svg = sig.toSVG(inkColor: "#000000", inkWidth: 2)
    let json = sig.toJSON()
    let sigString = sig.toSigString()
    print("\(sig.totalPoints) points, \(sig.strokes.count) strokes")
}

pad.close()
```

### Streaming API

```swift
let pad = try TopazKit.open(device: "/dev/cu.usbserial-TOPAZBSB")

pad.stream { packet in
    if packet.isPenData && packet.penDown {
        let (x, y) = pad.model.scaleCoords(rawX: packet.rawX, rawY: packet.rawY)
        print("x=\(x) y=\(y)")
    }
    return true  // return false to stop
}
```

### API

| Type | Description |
|------|-------------|
| `TopazKit.open(device?, model?)` | Connect to a pad (auto-detects if device is nil) |
| `TopazKit.detectDevices()` | List connected pad device paths |
| `TopazConnection.capture(timeout:)` | Blocking capture, returns `TopazSignature?` |
| `TopazConnection.stream(_:)` | Stream raw packets via callback |
| `TopazConnection.nextPacket()` | Read single packet (nil on timeout) |
| `TopazSignature.toSVG(...)` | Export to SVG string |
| `TopazSignature.toJSON()` | Export to JSON `Data` |
| `TopazSignature.toSigString()` | Export to Topaz SigString format |
| `TopazSignature.strokes` | Raw stroke data `[[(Double, Double)]]` |
| `TopazModels.get(name)` | Get model config by name |

Compile with: `swiftc -O YourApp.swift lib/TopazKit.swift`

## Stabilization

We surveyed the state of the art in pen stroke stabilization to choose the best algorithm for signature capture.

### Why not Catmull-Rom + RDP?

Catmull-Rom is an *interpolation* technique (makes curves look smooth between points) and Ramer-Douglas-Peucker is a *simplification* technique (reduces point count). Neither addresses the fundamental **jitter-vs-lag tradeoff** — the core problem in pen input. They're output-stage algorithms, not input-stage.

### The 1-Euro Filter (Casiez et al., CHI 2012)

We use the **[1-Euro Filter](https://gery.casiez.net/1euro/)**, an adaptive low-pass filter that adjusts its cutoff frequency based on signal speed:

- **Slow pen motion** (detail work): cutoff drops, heavy smoothing removes jitter
- **Fast pen motion** (broad strokes): cutoff rises, minimal smoothing reduces lag
- This matches human perception — we notice jitter when moving slowly and lag when moving fast

The math is simple: an exponential moving average where the smoothing factor `alpha` is derived from an adaptive cutoff frequency `fc = fc_min + beta * |velocity|`. Two parameters to tune: `mincutoff` (jitter threshold) and `beta` (lag reduction).

### Completion Detection

Instead of a fixed 5-second timeout, we use **proximity-based completion**:

1. **Pen leaves proximity** (bit 6 of status byte) → finalize in 0.5s
2. **Inter-stroke gap** exceeds 1.5s → finalize
3. **Absolute fallback** at 3s

This makes capture feel instant — the pad knows when you've pulled the pen away.

### Alternatives Considered

| Algorithm | Used by | Tradeoff |
|-----------|---------|----------|
| **1-Euro Filter** | This project, Krita (conceptually) | Best jitter/lag balance, trivial to implement |
| Spring-Mass-Damper | Google Ink Stroke Modeler, Inkscape | Natural feel, but rounds sharp corners |
| Pulled String | Lazy Nezumi, Photoshop | Best for sharp corners, zero lag, but adds dead zone |
| N-euro Predictor | Research (UbiComp 2023) | 36% better than 1-Euro, but requires neural network |
| Moving Average | Procreate StreamLine | Simple but fixed lag proportional to window size |
| Kalman Filter | Android stylus prediction | Excellent but moderate complexity |

The N-euro Predictor (UbiComp 2023) remains SOTA for neural pen prediction as of 2025. The closest newer work is a [self-distillation multi-task model](https://dl.acm.org/doi/10.1145/3743742) (PACM HCI 2025) achieving 0.47px error at 6ms prediction, and [TA-GNN](https://arxiv.org/abs/2503.13034) (OzCHI 2024) for time-agnostic motion prediction. However, neural approaches solve display latency compensation for real-time drawing — for signature capture and export, the 1-Euro filter's adaptive jitter removal is the right tool.

References:
- [1-Euro Filter](https://gery.casiez.net/1euro/) — Casiez, Roussel, Vogel (CHI 2012)
- [Google Ink Stroke Modeler](https://github.com/google/ink-stroke-modeler) — Spring-mass-damper pipeline
- [N-euro Predictor](https://dl.acm.org/doi/abs/10.1145/3610884) — Shao et al. (UbiComp 2023)
- [Self-Distillation Multi-task Learning](https://dl.acm.org/doi/10.1145/3743742) — Liu et al. (PACM HCI 2025)
- [TA-GNN / NeverLagging](https://arxiv.org/abs/2503.13034) — Li et al. (OzCHI 2024)
- [GRU-CNN Stylus Prediction](https://link.springer.com/chapter/10.1007/978-3-030-50726-8_32) — Kushnirenko & Alkhimova (Samsung Research, 2020)
- [LaViola - Double Exp. Smoothing vs Kalman](https://cs.brown.edu/people/jlaviola/pubs/kfvsexp_final_laviola.pdf)

## How This Was Built

1. Plugged in a Topaz T-LBK462-BSB-R — macOS recognized the FTDI chip automatically
2. Probed the serial port at 19200 baud with various byte commands
3. Got command responses but no pen data — the key problem
4. Downloaded and decompiled the SigPlus Java SDK v2.68
5. Found the critical setting in `TabletInterface.openTabletSerial()`: **odd parity** (not 8N1)
6. Pen data started streaming immediately with correct serial parameters
7. Decoded the 5-byte packet format from `processSerialInput()`
8. Built a Python prototype, then rewrote everything in Swift as a native macOS app

## License

[MIT](LICENSE.md)
