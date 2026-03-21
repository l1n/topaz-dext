# Topaz Signature Pad Driver for macOS

Native macOS driver and capture tool for [Topaz Systems](https://www.topazsystems.com/) USB signature pads. No official drivers needed — connects directly via the reverse-engineered serial protocol.

**[Try the web version](https://l1n.github.io/topaz-dext/)** (Chrome/Edge, Web Serial API)

## Features

- **305KB native arm64 binary**, zero dependencies, single Swift file
- **Menu bar app** with auto-capture daemon (no dock icon, no terminal)
- **CLI** for scripted capture, format conversion, comparison
- **Auto-crop** with transparent background — paste directly into documents
- **Stroke stabilization** (Catmull-Rom spline + Ramer-Douglas-Peucker simplification)
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

MIT
