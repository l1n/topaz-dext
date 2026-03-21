// TopazCapture.swift — Pure Swift Topaz Signature Pad Tool
// Compile: swiftc -O -sdk $(xcrun --show-sdk-path) -framework Cocoa -o topaz TopazCapture.swift

import Cocoa
import CoreGraphics
import Darwin

// MARK: - Model Database

struct TopazModel {
    let name: String
    let xStart, xStop, yStart, yStop: Int
    let logicalX, logicalY: Int
    let baud: Int
    let resolution, timingAdvance, filterPoints, format: Int

    static let defaultName = "SignatureGem1X5"

    static let all: [String: TopazModel] = [
        "SignatureGem1X5":    TopazModel(name: "SignatureGem1X5",    xStart: 400, xStop: 2400, yStart: 350, yStop:  950, logicalX: 2000, logicalY:  600, baud: 19200,  resolution: 410, timingAdvance: 4, filterPoints: 4, format: 0),
        "SignatureGemLCD1X5": TopazModel(name: "SignatureGemLCD1X5", xStart: 400, xStop: 2400, yStart: 350, yStop: 1250, logicalX: 2000, logicalY:  900, baud: 19200,  resolution: 410, timingAdvance: 4, filterPoints: 4, format: 1),
        "SignatureGem4X5":    TopazModel(name: "SignatureGem4X5",    xStart: 500, xStop: 2650, yStart: 700, yStop: 2100, logicalX: 2150, logicalY: 1400, baud: 19200,  resolution: 410, timingAdvance: 4, filterPoints: 4, format: 0),
        "SigLite1X5":         TopazModel(name: "SigLite1X5",         xStart: 500, xStop: 2650, yStart: 700, yStop: 2100, logicalX: 2150, logicalY: 1400, baud: 19200,  resolution: 410, timingAdvance: 2, filterPoints: 2, format: 0),
        "SigLiteLCD1X5":      TopazModel(name: "SigLiteLCD1X5",      xStart: 400, xStop: 2400, yStart: 350, yStop: 1050, logicalX: 2000, logicalY:  700, baud: 19200,  resolution: 410, timingAdvance: 0, filterPoints: 4, format: 0),
        "SigLiteLCD4X5":      TopazModel(name: "SigLiteLCD4X5",      xStart: 500, xStop: 2600, yStart: 500, yStop: 2100, logicalX: 2100, logicalY: 1600, baud: 38400,  resolution: 410, timingAdvance: 4, filterPoints: 4, format: 0),
        "ClipGem":            TopazModel(name: "ClipGem",            xStart: 485, xStop: 2800, yStart: 170, yStop: 3200, logicalX: 2315, logicalY: 3030, baud: 9600,   resolution: 275, timingAdvance: 1, filterPoints: 2, format: 0),
        "SigGemColor57":      TopazModel(name: "SigGemColor57",      xStart: 300, xStop: 2370, yStart: 350, yStop: 1950, logicalX: 2070, logicalY: 1600, baud: 115200, resolution: 410, timingAdvance: 4, filterPoints: 4, format: 0),
    ]

    static func get(_ name: String) -> TopazModel {
        return all[name] ?? all[defaultName]!
    }

    func scaleCoords(rawX: Int, rawY: Int) -> (Double, Double) {
        var x = Double(rawX - xStart) * Double(logicalX) / Double(xStop - xStart)
        var y = Double(rawY - yStart) * Double(logicalY) / Double(yStop - yStart)
        x = max(0, min(Double(logicalX), x))
        y = max(0, min(Double(logicalY), y))
        return (x, y)
    }
}

// MARK: - Packet Decoding

struct TopazPacket {
    let rawX, rawY: Int
    let penDown, penNear: Bool
    let packetType: Int
    let pressure: Int
    let modelNumber, serialNumber: Int
    let timestamp: TimeInterval

    var isPenData: Bool { packetType == 0 || packetType == 1 || packetType == 4 }
    var isPressureData: Bool { packetType == 7 }
    var isInfoData: Bool { packetType == 2 }
    var isBad: Bool { rawX == 0x0FFF && rawY == 0x0FFF }

    init(bytes: [UInt8], fmt: Int = 0) {
        let status = bytes[0]
        timestamp = ProcessInfo.processInfo.systemUptime
        penDown = (status & 0x01) != 0
        packetType = Int((status >> 2) & 7)

        if fmt == 0 {
            penNear = (status & 0x40) != 0
            rawX = (Int(bytes[2] & 0x1F) << 7) | Int(bytes[1] & 0x7F)
            rawY = (Int(bytes[4] & 0x1F) << 7) | Int(bytes[3] & 0x7F)
        } else {
            penNear = (status & 0x04) != 0
            rawX = (Int(bytes[2] & 0x3F) << 6) | Int(bytes[1] & 0x3F)
            rawY = (Int(bytes[4] & 0x3F) << 6) | Int(bytes[3] & 0x3F)
        }

        if packetType == 7 {
            pressure = (Int(bytes[4] & 0x07) << 7) | Int(bytes[3] & 0x7F)
        } else {
            pressure = 0
        }

        if packetType == 2 {
            let d0 = Int(bytes[1] & 0x7F) | (Int(bytes[2] & 0x7F) << 7)
            let d1 = Int(bytes[3] & 0x7F) | (Int(bytes[4] & 0x7F) << 7)
            modelNumber = (d0 & 0xFC) >> 2
            serialNumber = ((d0 & 0x03) << 16) | d1
        } else {
            modelNumber = 0
            serialNumber = 0
        }
    }
}

// MARK: - Point Filter

struct PointFilter {
    let size: Int
    var xBuf: [Int] = []
    var yBuf: [Int] = []

    init(size: Int = 4) { self.size = size }

    mutating func add(_ x: Int, _ y: Int) -> (Int, Int) {
        xBuf.append(x)
        yBuf.append(y)
        if xBuf.count > size { xBuf.removeFirst() }
        if yBuf.count > size { yBuf.removeFirst() }
        return (xBuf.reduce(0, +) / xBuf.count, yBuf.reduce(0, +) / yBuf.count)
    }

    mutating func clear() { xBuf.removeAll(); yBuf.removeAll() }
}

// MARK: - Stabilization

/// Applies Catmull-Rom spline interpolation to smooth a stroke
func stabilizeStroke(_ points: [(Double, Double)], tension: Double = 0.5) -> [(Double, Double)] {
    guard points.count >= 3 else { return points }
    var result: [(Double, Double)] = [points[0]]
    let n = points.count

    for i in 0..<(n - 1) {
        let p0 = points[max(0, i - 1)]
        let p1 = points[i]
        let p2 = points[min(n - 1, i + 1)]
        let p3 = points[min(n - 1, i + 2)]

        // Subdivide each segment into steps proportional to distance
        let dx = p2.0 - p1.0, dy = p2.1 - p1.1
        let dist = sqrt(dx*dx + dy*dy)
        let steps = max(2, Int(dist / 3))

        for s in 1...steps {
            let t = Double(s) / Double(steps)
            let t2 = t * t, t3 = t2 * t

            let x = 0.5 * ((2*p1.0) +
                (-p0.0 + p2.0) * t * tension +
                (2*p0.0 - 5*p1.0 + 4*p2.0 - p3.0) * t2 * tension +
                (-p0.0 + 3*p1.0 - 3*p2.0 + p3.0) * t3 * tension)
            let y = 0.5 * ((2*p1.1) +
                (-p0.1 + p2.1) * t * tension +
                (2*p0.1 - 5*p1.1 + 4*p2.1 - p3.1) * t2 * tension +
                (-p0.1 + 3*p1.1 - 3*p2.1 + p3.1) * t3 * tension)
            result.append((x, y))
        }
    }
    return result
}

/// Applies Ramer-Douglas-Peucker simplification then smoothing
func stabilizeSignature(_ sig: SignatureData, level: Int = 1) {
    for i in 0..<sig.strokes.count {
        var stroke = sig.strokes[i]
        if level >= 2 {
            // RDP simplification to remove jitter
            stroke = rdpSimplify(stroke, epsilon: Double(level) * 0.5)
        }
        if level >= 1 {
            // Catmull-Rom smoothing
            stroke = stabilizeStroke(stroke, tension: min(1.0, Double(level) * 0.5))
        }
        sig.strokes[i] = stroke
        // Resize pressure/timestamp arrays to match
        if sig.pressures[i].count != stroke.count {
            sig.pressures[i] = Array(repeating: 0, count: stroke.count)
        }
        if sig.timestamps[i].count != stroke.count {
            sig.timestamps[i] = Array(repeating: 0.0, count: stroke.count)
        }
    }
}

func rdpSimplify(_ points: [(Double, Double)], epsilon: Double) -> [(Double, Double)] {
    guard points.count > 2 else { return points }
    var maxDist = 0.0
    var maxIdx = 0

    let (ax, ay) = points.first!
    let (bx, by) = points.last!
    let dx = bx - ax, dy = by - ay
    let lenSq = dx*dx + dy*dy

    for i in 1..<(points.count - 1) {
        let dist: Double
        if lenSq < 1e-10 {
            let ex = points[i].0 - ax, ey = points[i].1 - ay
            dist = sqrt(ex*ex + ey*ey)
        } else {
            let t = max(0, min(1, ((points[i].0 - ax)*dx + (points[i].1 - ay)*dy) / lenSq))
            let px = ax + t*dx, py = ay + t*dy
            let ex = points[i].0 - px, ey = points[i].1 - py
            dist = sqrt(ex*ex + ey*ey)
        }
        if dist > maxDist { maxDist = dist; maxIdx = i }
    }

    if maxDist > epsilon {
        let left = rdpSimplify(Array(points[0...maxIdx]), epsilon: epsilon)
        let right = rdpSimplify(Array(points[maxIdx...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }
    return [points.first!, points.last!]
}

// MARK: - Signature Data

class SignatureData {
    let model: TopazModel
    var strokes: [[(Double, Double)]] = []
    var pressures: [[Int]] = []
    var timestamps: [[TimeInterval]] = []
    var captureStart: TimeInterval = 0
    var captureEnd: TimeInterval = 0
    var tabletModel: Int = 0
    var tabletSerial: Int = 0

    init(model: TopazModel = TopazModel.get(TopazModel.defaultName)) {
        self.model = model
    }

    var totalPoints: Int { strokes.reduce(0) { $0 + $1.count } }
    var hasPressure: Bool { pressures.contains { $0.contains { $0 > 0 } } }

    func addStroke(_ points: [(Double, Double)], pressures p: [Int], timestamps t: [TimeInterval]) {
        guard points.count >= 2 else { return }
        strokes.append(points)
        pressures.append(p)
        timestamps.append(t)
    }

    // -- SigString --

    func toSigString() -> String {
        var lines: [String] = []
        lines.append("\(totalPoints)")
        lines.append("\(strokes.count)")
        for stroke in strokes {
            for (x, y) in stroke { lines.append("\(Int(x)) \(Int(y))") }
        }
        var cumulative = 0
        for stroke in strokes {
            cumulative += stroke.count - 1
            lines.append("\(cumulative)")
        }
        let raw = lines.joined(separator: "\r\n")
        return raw.data(using: .ascii)!.map { String(format: "%02X", $0) }.joined()
    }

    static func fromSigString(_ hex: String, model: TopazModel? = nil) -> SignatureData {
        let sig = SignatureData(model: model ?? TopazModel.get(TopazModel.defaultName))
        guard let data = hexToData(hex) else { return sig }
        guard let raw = String(data: data, encoding: .ascii) else { return sig }
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init)
        guard lines.count >= 2, let totalPts = Int(lines[0]), let numStrokes = Int(lines[1]) else { return sig }

        var coords: [(Double, Double)] = []
        for i in 2..<min(2 + totalPts, lines.count) {
            let parts = lines[i].split(separator: " ")
            if parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]) { coords.append((x, y)) }
        }
        var endpoints: [Int] = []
        for i in (2 + totalPts)..<min(2 + totalPts + numStrokes, lines.count) {
            if let ep = Int(lines[i]) { endpoints.append(ep) }
        }
        var start = 0
        for ep in endpoints {
            let end = min(ep + 1, coords.count)
            let stroke = Array(coords[start..<end])
            if stroke.count >= 2 {
                sig.strokes.append(stroke)
                sig.pressures.append(Array(repeating: 0, count: stroke.count))
                sig.timestamps.append(Array(repeating: 0.0, count: stroke.count))
            }
            start = end
        }
        return sig
    }

    // -- Biometrics --

    func computeBiometrics() -> [String: Any] {
        var strokeBios: [[String: Any]] = []
        for (i, stroke) in strokes.enumerated() {
            guard stroke.count >= 2 else { continue }
            let times = i < timestamps.count ? timestamps[i] : Array(repeating: 0.0, count: stroke.count)
            let pres = i < pressures.count ? pressures[i] : Array(repeating: 0, count: stroke.count)
            var pathLen = 0.0, vels: [Double] = [], prevV = 0.0

            for j in 1..<stroke.count {
                let dx = stroke[j].0 - stroke[j-1].0, dy = stroke[j].1 - stroke[j-1].1
                let dist = sqrt(dx*dx + dy*dy)
                pathLen += dist
                let dt = max(0.005, times[j] - times[j-1])
                let v = dist / dt
                vels.append(v)
                prevV = v
            }
            _ = prevV // silence warning
            let pvals = pres.filter { $0 > 0 }
            let dur = times.count >= 2 ? (times.last! - times.first!) * 1000 : 0
            strokeBios.append([
                "stroke_index": i, "point_count": stroke.count, "duration_ms": Int(dur),
                "path_length": round(pathLen * 10) / 10,
                "avg_velocity": vels.isEmpty ? 0 : round(vels.reduce(0, +) / Double(vels.count) * 10) / 10,
                "max_velocity": vels.isEmpty ? 0 : round(vels.max()! * 10) / 10,
                "avg_pressure": pvals.isEmpty ? 0 : pvals.reduce(0, +) / pvals.count,
                "max_pressure": pvals.max() ?? 0,
            ])
        }
        return [
            "total_points": totalPoints, "total_strokes": strokes.count,
            "duration_ms": Int((captureEnd - captureStart) * 1000), "strokes": strokeBios,
        ]
    }

    // -- JSON --

    func toJSON() -> Data {
        let dict: [String: Any] = [
            "model": model.name,
            "strokes": strokes.map { $0.map { [$0.0, $0.1] } },
            "pressures": pressures, "timestamps": timestamps,
            "capture_start": captureStart, "capture_end": captureEnd,
            "tablet_model_number": tabletModel, "tablet_serial_number": tabletSerial,
            "biometrics": computeBiometrics(),
        ]
        return try! JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
    }

    static func fromJSON(_ data: Data) -> SignatureData? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let sig = SignatureData(model: TopazModel.get(dict["model"] as? String ?? TopazModel.defaultName))
        if let s = dict["strokes"] as? [[[Double]]] { sig.strokes = s.map { $0.map { ($0[0], $0[1]) } } }
        if let p = dict["pressures"] as? [[Int]] { sig.pressures = p }
        if let t = dict["timestamps"] as? [[Double]] { sig.timestamps = t }
        sig.captureStart = dict["capture_start"] as? Double ?? 0
        sig.captureEnd = dict["capture_end"] as? Double ?? 0
        sig.tabletModel = dict["tablet_model_number"] as? Int ?? 0
        sig.tabletSerial = dict["tablet_serial_number"] as? Int ?? 0
        return sig
    }

    func save(to path: String) {
        try? toJSON().write(to: URL(fileURLWithPath: path))
        print("Saved JSON: \(path)")
    }

    static func load(from path: String) -> SignatureData? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "json" { return fromJSON(data) }
        if ext == "sigstring" {
            guard let hex = String(data: data, encoding: .utf8) else { return nil }
            return fromSigString(hex.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if ext == "svg" { return fromSVG(data) }
        return nil
    }

    static func fromSVG(_ data: Data) -> SignatureData? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let sig = SignatureData()
        var searchRange = str.startIndex..<str.endIndex
        while let r1 = str.range(of: "points=\"", range: searchRange) {
            let start = r1.upperBound
            guard let r2 = str.range(of: "\"", range: start..<str.endIndex) else { break }
            let pointsStr = String(str[start..<r2.lowerBound])
            var points: [(Double, Double)] = []
            for pair in pointsStr.split(separator: " ") {
                let xy = pair.split(separator: ",")
                if xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) { points.append((x, y)) }
            }
            if points.count >= 2 {
                sig.strokes.append(points)
                sig.pressures.append(Array(repeating: 0, count: points.count))
                sig.timestamps.append(Array(repeating: 0.0, count: points.count))
            }
            searchRange = r2.upperBound..<str.endIndex
        }
        return sig.strokes.isEmpty ? nil : sig
    }

    static func hexToData(_ hex: String) -> Data? {
        var data = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            guard let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) else { break }
            guard let byte = UInt8(hex[i..<next], radix: 16) else { return nil }
            data.append(byte)
            i = next
        }
        return data
    }
}

// MARK: - Serial Port (POSIX termios)

class SerialPort {
    let fd: Int32
    let path: String

    init(path: String, baud: Int, dataBits: Int = 8, parity: Bool = true, oddParity: Bool = true) throws {
        self.path = path
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw NSError(domain: "SerialPort", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }

        var flags = fcntl(fd, F_GETFL)
        flags &= ~O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)
        _ = ioctl(fd, TIOCEXCL)

        var options = termios()
        tcgetattr(fd, &options)

        let speed = Self.baudConstant(baud)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(dataBits == 7 ? CS7 : CS8)

        if parity {
            options.c_cflag |= tcflag_t(PARENB)
            if oddParity { options.c_cflag |= tcflag_t(PARODD) }
            else { options.c_cflag &= ~tcflag_t(PARODD) }
        } else {
            options.c_cflag &= ~tcflag_t(PARENB)
        }

        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)

        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY | ISTRIP)
        if parity { options.c_iflag |= tcflag_t(INPCK) }
        else { options.c_iflag &= ~tcflag_t(INPCK) }
        options.c_oflag &= ~tcflag_t(OPOST)

        withUnsafeMutableBytes(of: &options.c_cc) { ptr in
            ptr[Int(VMIN)] = 0
            ptr[Int(VTIME)] = 1
        }

        options.c_iflag &= ~tcflag_t(ICRNL | INLCR | IGNCR)
        tcsetattr(fd, TCSANOW, &options)
        tcflush(fd, TCIOFLUSH)
    }

    func read(maxBytes: Int = 64) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = Darwin.read(fd, &buffer, maxBytes)
        return n > 0 ? Data(buffer[0..<n]) : nil
    }

    func flush() { tcflush(fd, TCIFLUSH) }
    func close() { Darwin.close(fd) }
    deinit { close() }

    static func baudConstant(_ rate: Int) -> speed_t {
        switch rate {
        case 4800:   return speed_t(B4800)
        case 9600:   return speed_t(B9600)
        case 19200:  return speed_t(B19200)
        case 38400:  return speed_t(B38400)
        case 57600:  return speed_t(B57600)
        case 115200: return speed_t(B115200)
        default:     return speed_t(B19200)
        }
    }
}

// MARK: - Packet Reader

class PacketReader {
    let port: SerialPort
    let format: Int
    var state = 0
    var buf: [UInt8] = []

    init(port: SerialPort, format: Int = 0) {
        self.port = port
        self.format = format
    }

    func isStartByte(_ b: UInt8) -> Bool {
        format == 0 ? (b & 0x80) != 0 : (b & 0x70) != 0x30
    }

    func next() -> TopazPacket? {
        guard let data = port.read(maxBytes: 64) else { return nil }
        for byte in data {
            let start = isStartByte(byte)
            switch state {
            case 0:
                if start { buf = [byte]; state = 1 }
            case 1:
                if start { buf = [byte] }
                else { buf.append(byte); state = 2 }
            case 2:
                if start { buf = [byte]; state = 1 }
                else {
                    buf.append(byte)
                    if buf.count == 5 {
                        let bad = format == 0 && buf[1...4].contains { $0 & 0x80 != 0 }
                        state = 0
                        if !bad {
                            let pkt = TopazPacket(bytes: buf, fmt: format)
                            buf = []
                            if !pkt.isBad { return pkt }
                        }
                        buf = []
                    }
                }
            default: state = 0
            }
        }
        return nil
    }
}

// MARK: - Device Detection

func detectDevices() -> [String] {
    var gt = glob_t()
    guard Darwin.glob("/dev/cu.usbserial-TOPAZ*", GLOB_TILDE, nil, &gt) == 0 else {
        globfree(&gt); return []
    }
    var results: [String] = []
    for i in 0..<Int(gt.gl_matchc) {
        if let p = gt.gl_pathv[i] { results.append(String(cString: p)) }
    }
    globfree(&gt)
    return results.sorted()
}

let defaultDevice = "/dev/cu.usbserial-TOPAZBSB"

// MARK: - Color Parsing

func parseColor(_ str: String) -> NSColor {
    let named: [String: NSColor] = [
        "black": .black, "white": .white, "blue": NSColor(red: 0, green: 0, blue: 0.5, alpha: 1),
        "red": NSColor(red: 0.7, green: 0, blue: 0, alpha: 1), "transparent": .clear,
    ]
    if let c = named[str] { return c }
    let hex = str.hasPrefix("#") ? String(str.dropFirst()) : str
    guard hex.count >= 6 else { return .black }
    let r = Double(Int(hex.prefix(2), radix: 16) ?? 0) / 255
    let g = Double(Int(hex.dropFirst(2).prefix(2), radix: 16) ?? 0) / 255
    let b = Double(Int(hex.dropFirst(4).prefix(2), radix: 16) ?? 0) / 255
    let a = hex.count >= 8 ? Double(Int(hex.dropFirst(6).prefix(2), radix: 16) ?? 255) / 255 : 1.0
    return NSColor(red: r, green: g, blue: b, alpha: a)
}

// MARK: - Export: SVG

func exportSVG(_ sig: SignatureData, to path: String, inkColor: String = "#000000",
               inkWidth: Double = 2.0, bgColor: String = "transparent", padding: Double = 20) {
    // Auto-crop to bounding box
    let originX: Double, originY: Double, w: Double, h: Double
    if let b = strokeBounds(sig, inkWidth: CGFloat(inkWidth)) {
        originX = b.minX - padding
        originY = b.minY - padding
        w = (b.maxX - b.minX) + padding * 2
        h = (b.maxY - b.minY) + padding * 2
    } else {
        originX = 0; originY = 0
        w = Double(sig.model.logicalX) + padding * 2
        h = Double(sig.model.logicalY) + padding * 2
    }

    var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(Int(w)) \(Int(h))\" width=\"\(Int(w))\" height=\"\(Int(h))\">"
    if bgColor != "transparent" {
        svg += "\n  <rect width=\"\(Int(w))\" height=\"\(Int(h))\" fill=\"\(bgColor)\"/>"
    }
    for (i, stroke) in sig.strokes.enumerated() {
        guard stroke.count >= 2 else { continue }
        let sp = sig.hasPressure && i < sig.pressures.count ? sig.pressures[i] : nil
        if let sp = sp, sp.count == stroke.count {
            for j in 0..<stroke.count - 1 {
                let (x0, y0) = stroke[j]; let (x1, y1) = stroke[j+1]
                let pv = sp[j] > 0 ? Double(sp[j]) / 1023.0 : 0.5
                let sw = inkWidth * (0.3 + pv * 1.7), op = 0.4 + pv * 0.6
                svg += "\n  <line x1=\"\(x0-originX)\" y1=\"\(y0-originY)\" x2=\"\(x1-originX)\" y2=\"\(y1-originY)\" stroke=\"\(inkColor)\" stroke-opacity=\"\(String(format: "%.2f", op))\" stroke-width=\"\(String(format: "%.1f", sw))\" stroke-linecap=\"round\"/>"
            }
        } else {
            let pts = stroke.map { "\(String(format: "%.1f", $0.0-originX)),\(String(format: "%.1f", $0.1-originY))" }.joined(separator: " ")
            svg += "\n  <polyline points=\"\(pts)\" fill=\"none\" stroke=\"\(inkColor)\" stroke-width=\"\(inkWidth)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }
    }
    svg += "\n</svg>"
    try? svg.write(toFile: path, atomically: true, encoding: .utf8)
    print("Saved SVG: \(path)")
}

// MARK: - Export: Raster

/// Compute bounding box of all strokes, with padding for stroke width.
func strokeBounds(_ sig: SignatureData, inkWidth: CGFloat) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
    let allPts = sig.strokes.flatMap { $0 }
    guard !allPts.isEmpty else { return nil }
    let pad = Double(inkWidth) * 2
    return (
        (allPts.map { $0.0 }.min()!) - pad,
        (allPts.map { $0.1 }.min()!) - pad,
        (allPts.map { $0.0 }.max()!) + pad,
        (allPts.map { $0.1 }.max()!) + pad
    )
}

func renderSignature(_ sig: SignatureData, inkColor: NSColor, inkWidth: CGFloat,
                     bgColor: NSColor, padding: CGFloat, scale: CGFloat,
                     autoCrop: Bool = true) -> CGImage? {
    // Determine canvas bounds
    let originX: CGFloat, originY: CGFloat, canvasW: CGFloat, canvasH: CGFloat
    if autoCrop, let b = strokeBounds(sig, inkWidth: inkWidth) {
        originX = CGFloat(b.minX) - padding
        originY = CGFloat(b.minY) - padding
        canvasW = CGFloat(b.maxX - b.minX) + padding * 2
        canvasH = CGFloat(b.maxY - b.minY) + padding * 2
    } else {
        originX = 0; originY = 0
        canvasW = CGFloat(sig.model.logicalX) + padding * 2
        canvasH = CGFloat(sig.model.logicalY) + padding * 2
    }

    let imgW = max(1, Int(canvasW * scale))
    let imgH = max(1, Int(canvasH * scale))
    guard let ctx = CGContext(data: nil, width: imgW, height: imgH,
                              bitsPerComponent: 8, bytesPerRow: imgW * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(imgH))
    ctx.scaleBy(x: 1, y: -1)

    if bgColor != .clear {
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))
    }

    ctx.setLineCap(.round); ctx.setLineJoin(.round)

    for (i, stroke) in sig.strokes.enumerated() {
        guard stroke.count >= 2 else { continue }
        let sp = sig.hasPressure && i < sig.pressures.count ? sig.pressures[i] : nil
        for j in 0..<stroke.count - 1 {
            let (x0, y0) = stroke[j]; let (x1, y1) = stroke[j+1]
            var sw = inkWidth, alpha = inkColor.alphaComponent
            if let sp = sp, j < sp.count, sp[j] > 0 {
                let pv = CGFloat(sp[j]) / 1023.0
                sw = inkWidth * (0.3 + pv * 1.7); alpha = 0.4 + pv * 0.6
            }
            let color = inkColor.withAlphaComponent(alpha)
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(sw * scale)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: (CGFloat(x0) - originX) * scale, y: (CGFloat(y0) - originY) * scale))
            ctx.addLine(to: CGPoint(x: (CGFloat(x1) - originX) * scale, y: (CGFloat(y1) - originY) * scale))
            ctx.strokePath()
        }
    }
    return ctx.makeImage()
}

func exportImage(_ sig: SignatureData, to path: String, format: String = "png",
                 inkColor: String = "#000000", inkWidth: Double = 3,
                 bgColor: String = "transparent", padding: Double = 20, scale: Double = 2) {
    let ink = parseColor(inkColor)
    let bg = bgColor == "transparent" ? NSColor.clear : parseColor(bgColor)
    guard let cgImage = renderSignature(sig, inkColor: ink, inkWidth: CGFloat(inkWidth),
                                         bgColor: bg, padding: CGFloat(padding), scale: CGFloat(scale),
                                         autoCrop: true) else { return }
    let fmt = format.lowercased()
    let needsOpaque = (fmt == "jpeg" || fmt == "jpg" || fmt == "bmp")
    let finalImage: CGImage
    if needsOpaque && bg == .clear {
        // Composite onto white for formats that don't support alpha
        let w = cgImage.width, h = cgImage.height
        guard let ctx2 = CGContext(data: nil, width: w, height: h,
                                    bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx2.setFillColor(NSColor.white.cgColor)
        ctx2.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx2.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        finalImage = ctx2.makeImage() ?? cgImage
    } else {
        finalImage = cgImage
    }

    let rep = NSBitmapImageRep(cgImage: finalImage)
    let imageData: Data?
    switch fmt {
    case "jpeg", "jpg": imageData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])
    case "tiff", "tif": imageData = rep.representation(using: .tiff, properties: [:])
    case "bmp": imageData = rep.representation(using: .bmp, properties: [:])
    default: imageData = rep.representation(using: .png, properties: [:])
    }
    if let data = imageData {
        try? data.write(to: URL(fileURLWithPath: path))
        print("Saved \(fmt.uppercased()): \(path) (\(cgImage.width)x\(cgImage.height))")
    }
}

func exportPDF(_ sig: SignatureData, to path: String, inkColor: String = "#000000",
               inkWidth: Double = 2, padding: Double = 20) {
    let ink = parseColor(inkColor)
    let originX: CGFloat, originY: CGFloat, w: CGFloat, h: CGFloat
    if let b = strokeBounds(sig, inkWidth: CGFloat(inkWidth)) {
        originX = CGFloat(b.minX) - CGFloat(padding)
        originY = CGFloat(b.minY) - CGFloat(padding)
        w = CGFloat(b.maxX - b.minX) + CGFloat(padding) * 2
        h = CGFloat(b.maxY - b.minY) + CGFloat(padding) * 2
    } else {
        originX = 0; originY = 0
        w = CGFloat(sig.model.logicalX) + CGFloat(padding) * 2
        h = CGFloat(sig.model.logicalY) + CGFloat(padding) * 2
    }
    var mediaBox = CGRect(x: 0, y: 0, width: w, height: h)
    guard let ctx = CGContext(URL(fileURLWithPath: path) as CFURL, mediaBox: &mediaBox, nil) else { return }
    ctx.beginPDFPage(nil)
    ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
    ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setStrokeColor(ink.cgColor)
    for (i, stroke) in sig.strokes.enumerated() {
        guard stroke.count >= 2 else { continue }
        let sp = sig.hasPressure && i < sig.pressures.count ? sig.pressures[i] : nil
        for j in 0..<stroke.count - 1 {
            var sw = CGFloat(inkWidth), alpha: CGFloat = 1.0
            if let sp = sp, j < sp.count, sp[j] > 0 {
                let pv = CGFloat(sp[j]) / 1023.0
                sw = CGFloat(inkWidth) * (0.3 + pv * 1.7); alpha = 0.4 + pv * 0.6
            }
            ctx.setStrokeColor(ink.withAlphaComponent(alpha).cgColor); ctx.setLineWidth(sw)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: CGFloat(stroke[j].0) - originX, y: CGFloat(stroke[j].1) - originY))
            ctx.addLine(to: CGPoint(x: CGFloat(stroke[j+1].0) - originX, y: CGFloat(stroke[j+1].1) - originY))
            ctx.strokePath()
        }
    }
    ctx.endPDFPage(); ctx.closePDF()
    print("Saved PDF: \(path)")
}

// MARK: - Clipboard & Notification

func copyToClipboard(_ path: String) {
    guard let image = NSImage(contentsOfFile: path) else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
    print("Copied to clipboard")
}

func sendNotification(_ title: String, _ message: String, sound: Bool = false) {
    let soundClause = sound ? " sound name \"Glass\"" : ""
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", "display notification \"\(message)\" with title \"\(title)\"\(soundClause)"]
    try? task.run()
}

// MARK: - Headless Capture (no terminal needed)

/// Captures a signature without terminal interaction. Used by daemon and menu bar.
/// Returns the SignatureData, or nil if nothing captured.
func headlessCapture(device: String, model: TopazModel, timeout: TimeInterval = 10,
                     stabilize: Int = 0) -> SignatureData? {
    let port: SerialPort
    do { port = try SerialPort(path: device, baud: model.baud, dataBits: model.format == 1 ? 7 : 8) }
    catch { return nil }

    usleep(300_000); port.flush()

    let sig = SignatureData(model: model)
    sig.captureStart = ProcessInfo.processInfo.systemUptime
    let reader = PacketReader(port: port, format: model.format)
    var pf = PointFilter(size: model.filterPoints)
    var currentStroke: [(Double, Double)] = []
    var currentPressures: [Int] = []
    var currentTimestamps: [TimeInterval] = []
    var penWasDown = false
    var currentPressure = 0
    var lastActivity = ProcessInfo.processInfo.systemUptime
    var totalPoints = 0

    while true {
        if let packet = reader.next() {
            if packet.isPressureData { currentPressure = packet.pressure; continue }
            if packet.isInfoData {
                sig.tabletModel = packet.modelNumber; sig.tabletSerial = packet.serialNumber; continue
            }
            guard packet.isPenData else { continue }
            lastActivity = ProcessInfo.processInfo.systemUptime

            if packet.penDown {
                let (rx, ry) = model.scaleCoords(rawX: packet.rawX, rawY: packet.rawY)
                let (fx, fy) = pf.add(Int(rx), Int(ry))
                if !penWasDown {
                    currentStroke = [(Double(fx), Double(fy))]
                    currentPressures = [currentPressure]; currentTimestamps = [packet.timestamp]
                    penWasDown = true
                } else {
                    currentStroke.append((Double(fx), Double(fy)))
                    currentPressures.append(currentPressure); currentTimestamps.append(packet.timestamp)
                }
                totalPoints += 1
            } else if penWasDown {
                sig.addStroke(currentStroke, pressures: currentPressures, timestamps: currentTimestamps)
                currentStroke = []; currentPressures = []; currentTimestamps = []
                penWasDown = false; pf.clear()
                lastActivity = ProcessInfo.processInfo.systemUptime
            }
        } else {
            if totalPoints > 0 && !penWasDown &&
               ProcessInfo.processInfo.systemUptime - lastActivity > timeout { break }
        }
    }

    port.close()
    if penWasDown && currentStroke.count >= 2 {
        sig.addStroke(currentStroke, pressures: currentPressures, timestamps: currentTimestamps)
    }
    sig.captureEnd = ProcessInfo.processInfo.systemUptime

    if sig.totalPoints < 5 { return nil }
    if stabilize > 0 { stabilizeSignature(sig, level: stabilize) }
    return sig
}

/// Saves all output formats and copies to clipboard. Returns base filename.
func saveSignature(_ sig: SignatureData, output: String? = nil, format: String = "svg",
                   inkColor: String = "#000000", inkWidth: Double = 2.0, bgColor: String = "transparent",
                   dir: String? = nil) -> String {
    let ts = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"; return f.string(from: Date()) }()
    let prefix = dir.map { "\($0)/sig_\(ts)" } ?? (output.map { ($0 as NSString).deletingPathExtension } ?? "signature_\(ts)")

    switch format {
    case "pdf": exportPDF(sig, to: prefix + ".pdf", inkColor: inkColor, inkWidth: inkWidth)
    case "png", "bmp", "jpeg", "jpg", "tiff", "tif":
        exportImage(sig, to: prefix + ".\(format)", format: format, inkColor: inkColor, inkWidth: inkWidth, bgColor: bgColor)
    default: exportSVG(sig, to: prefix + ".svg", inkColor: inkColor, inkWidth: inkWidth, bgColor: bgColor)
    }
    if format != "png" { exportImage(sig, to: prefix + ".png", inkColor: inkColor, inkWidth: inkWidth, bgColor: bgColor) }
    if format != "svg" { exportSVG(sig, to: prefix + ".svg", inkColor: inkColor, inkWidth: inkWidth, bgColor: bgColor) }
    sig.save(to: prefix + ".json")
    try? sig.toSigString().write(toFile: prefix + ".sigstring", atomically: true, encoding: .utf8)
    print("Saved SigString: \(prefix).sigstring")
    copyToClipboard(prefix + ".png")
    return prefix
}

// MARK: - CLI Capture (terminal)

var captureRunning = true
func signalHandler(_ sig: Int32) { captureRunning = false }

func cliCapture(device: String, model: TopazModel, output: String?, format: String,
                timeout: Int, inkColor: String, inkWidth: Double, bgColor: String,
                filterSize: Int?, stabilize: Int) -> String? {
    captureRunning = true
    signal(SIGINT, signalHandler)

    let port: SerialPort
    do { port = try SerialPort(path: device, baud: model.baud, dataBits: model.format == 1 ? 7 : 8) }
    catch { print("Cannot open \(device): \(error)"); return nil }

    usleep(300_000); port.flush()
    print("Opening \(device) at \(model.baud) baud (8O1)...")
    print("Ready! Draw your signature on the pad.")
    print("Press Ctrl+C to save and exit.")
    if timeout > 0 { print("Auto-saves after \(timeout)s of inactivity.") }
    if stabilize > 0 { print("Stabilization level: \(stabilize)") }

    let sig = SignatureData(model: model)
    sig.captureStart = ProcessInfo.processInfo.systemUptime
    let reader = PacketReader(port: port, format: model.format)
    var pf = PointFilter(size: filterSize ?? model.filterPoints)
    var currentStroke: [(Double, Double)] = []
    var currentPressures: [Int] = []
    var currentTimestamps: [TimeInterval] = []
    var penWasDown = false
    var currentPressure = 0
    var lastActivity = Date()
    var totalPoints = 0

    while captureRunning {
        if let packet = reader.next() {
            if packet.isPressureData { currentPressure = packet.pressure; continue }
            if packet.isInfoData { sig.tabletModel = packet.modelNumber; sig.tabletSerial = packet.serialNumber; continue }
            guard packet.isPenData else { continue }
            lastActivity = Date()
            if packet.penDown {
                let (rx, ry) = model.scaleCoords(rawX: packet.rawX, rawY: packet.rawY)
                let (fx, fy) = pf.add(Int(rx), Int(ry))
                if !penWasDown {
                    currentStroke = [(Double(fx), Double(fy))]
                    currentPressures = [currentPressure]; currentTimestamps = [packet.timestamp]
                    penWasDown = true
                    print("+", terminator: ""); fflush(stdout)
                } else {
                    currentStroke.append((Double(fx), Double(fy)))
                    currentPressures.append(currentPressure); currentTimestamps.append(packet.timestamp)
                }
                totalPoints += 1
                if totalPoints % 50 == 0 { print(".", terminator: ""); fflush(stdout) }
            } else if penWasDown {
                sig.addStroke(currentStroke, pressures: currentPressures, timestamps: currentTimestamps)
                currentStroke = []; currentPressures = []; currentTimestamps = []
                penWasDown = false; pf.clear()
                print(" ", terminator: ""); fflush(stdout)
            }
        } else {
            if timeout > 0 && totalPoints > 0 && Date().timeIntervalSince(lastActivity) > Double(timeout) {
                print("\nAuto-saving after \(timeout)s of inactivity..."); break
            }
        }
    }
    port.close()
    if penWasDown && currentStroke.count >= 2 {
        sig.addStroke(currentStroke, pressures: currentPressures, timestamps: currentTimestamps)
    }
    sig.captureEnd = ProcessInfo.processInfo.systemUptime
    print("\nCapture complete: \(sig.totalPoints) points, \(sig.strokes.count) strokes")
    guard !sig.strokes.isEmpty else { print("No signature data captured."); return nil }

    if stabilize > 0 { stabilizeSignature(sig, level: stabilize) }
    let base = saveSignature(sig, output: output, format: format, inkColor: inkColor, inkWidth: inkWidth, bgColor: bgColor)
    return base
}

// MARK: - Daemon

class TopazDaemon {
    let model: TopazModel
    let device: String?
    let saveDir: String
    let idleTimeout: TimeInterval
    let inkColor: String
    let inkWidth: Double
    let stabilize: Int
    var running = true

    init(model: TopazModel, device: String? = nil, saveDir: String? = nil,
         idleTimeout: TimeInterval = 2.0, inkColor: String = "#000000",
         inkWidth: Double = 2.0, stabilize: Int = 0) {
        self.model = model
        self.device = device
        self.saveDir = saveDir ?? NSString(string: "~/Documents/Topaz Signatures").expandingTildeInPath
        self.idleTimeout = idleTimeout
        self.inkColor = inkColor
        self.inkWidth = inkWidth
        self.stabilize = stabilize
        try? FileManager.default.createDirectory(atPath: self.saveDir, withIntermediateDirectories: true)
    }

    func findDevice() -> String? {
        if let d = device, FileManager.default.fileExists(atPath: d) { return d }
        return detectDevices().first
    }

    func run() {
        print("Topaz daemon starting")
        while running {
            print("Waiting for Topaz pad...")
            var dev: String? = nil
            while running { dev = findDevice(); if dev != nil { break }; usleep(2_000_000) }
            guard running, let device = dev else { break }
            print("Found device: \(device)")
            captureLoop(device: device)
            if running { print("Reconnecting in 2s..."); usleep(2_000_000) }
        }
        print("Topaz daemon stopped")
    }

    func captureLoop(device: String) {
        let port: SerialPort
        do { port = try SerialPort(path: device, baud: model.baud, dataBits: model.format == 1 ? 7 : 8) }
        catch { print("Cannot open \(device): \(error)"); return }
        usleep(300_000); port.flush()
        print("Listening on \(device)...")
        sendNotification("Topaz Pad", "Signature pad connected and ready")

        let reader = PacketReader(port: port, format: model.format)
        var pf = PointFilter(size: model.filterPoints)
        var sig: SignatureData? = nil
        var currentStroke: [(Double, Double)] = []
        var currentPressures: [Int] = []
        var currentTimestamps: [TimeInterval] = []
        var penWasDown = false
        var currentPressure = 0
        var lastPenActivity: TimeInterval = 0

        while running {
            if let packet = reader.next() {
                if packet.isPressureData { currentPressure = packet.pressure; continue }
                if packet.isInfoData { sig?.tabletModel = packet.modelNumber; sig?.tabletSerial = packet.serialNumber; continue }
                guard packet.isPenData else { continue }
                if packet.penDown {
                    if sig == nil { sig = SignatureData(model: model); sig!.captureStart = ProcessInfo.processInfo.systemUptime; print("Capture started") }
                    let (rx, ry) = model.scaleCoords(rawX: packet.rawX, rawY: packet.rawY)
                    let (fx, fy) = pf.add(Int(rx), Int(ry))
                    if !penWasDown {
                        currentStroke = [(Double(fx), Double(fy))]; currentPressures = [currentPressure]; currentTimestamps = [packet.timestamp]; penWasDown = true
                    } else {
                        currentStroke.append((Double(fx), Double(fy))); currentPressures.append(currentPressure); currentTimestamps.append(packet.timestamp)
                    }
                    lastPenActivity = ProcessInfo.processInfo.systemUptime
                } else if penWasDown {
                    sig?.addStroke(currentStroke, pressures: currentPressures, timestamps: currentTimestamps)
                    currentStroke = []; currentPressures = []; currentTimestamps = []; penWasDown = false; pf.clear()
                    lastPenActivity = ProcessInfo.processInfo.systemUptime
                }
            } else {
                if let s = sig, s.totalPoints >= 5 && !penWasDown && lastPenActivity > 0 {
                    if ProcessInfo.processInfo.systemUptime - lastPenActivity > idleTimeout {
                        if stabilize > 0 { stabilizeSignature(s, level: stabilize) }
                        _ = saveSignature(s, inkColor: inkColor, inkWidth: inkWidth, dir: saveDir)
                        sendNotification("Signature Captured", "\(s.totalPoints) points, \(s.strokes.count) strokes — copied to clipboard", sound: true)
                        sig = nil; lastPenActivity = 0
                    }
                }
            }
        }
        if penWasDown && currentStroke.count >= 2 { sig?.addStroke(currentStroke, pressures: currentPressures, timestamps: currentTimestamps) }
        if let s = sig, s.totalPoints >= 5 {
            if stabilize > 0 { stabilizeSignature(s, level: stabilize) }
            _ = saveSignature(s, inkColor: inkColor, inkWidth: inkWidth, dir: saveDir)
        }
        port.close()
    }
}

// MARK: - LaunchAgent

func installLaunchAgent() {
    let binary = CommandLine.arguments[0]
    let absPath = binary.hasPrefix("/") ? binary : FileManager.default.currentDirectoryPath + "/" + binary
    let label = "com.topaz.signature-daemon"
    let plistPath = NSString(string: "~/Library/LaunchAgents/\(label).plist").expandingTildeInPath
    let logPath = NSString(string: "~/Library/Logs/topaz-daemon.log").expandingTildeInPath
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
        <key>Label</key><string>\(label)</string>
        <key>ProgramArguments</key><array>
            <string>\(absPath)</string><string>daemon</string><string>run</string>
        </array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
        <key>StandardOutPath</key><string>\(logPath)</string>
        <key>StandardErrorPath</key><string>\(logPath)</string>
    </dict></plist>
    """
    try? FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
    print("Installed: \(plistPath)")
    let u = Process(); u.executableURL = URL(fileURLWithPath: "/bin/launchctl"); u.arguments = ["unload", plistPath]; try? u.run(); u.waitUntilExit()
    let l = Process(); l.executableURL = URL(fileURLWithPath: "/bin/launchctl"); l.arguments = ["load", plistPath]; try? l.run(); l.waitUntilExit()
    print("Daemon loaded!")
}

func uninstallLaunchAgent() {
    let label = "com.topaz.signature-daemon"
    let plistPath = NSString(string: "~/Library/LaunchAgents/\(label).plist").expandingTildeInPath
    if FileManager.default.fileExists(atPath: plistPath) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = ["unload", plistPath]; try? p.run(); p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: plistPath); print("Uninstalled")
    } else { print("Not installed") }
}

// MARK: - Menu Bar App

class MenuBarApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var daemon: TopazDaemon?
    var daemonQueue = DispatchQueue(label: "topaz.daemon", qos: .background)
    var isConnected = false
    let saveDir = NSString(string: "~/Documents/Topaz Signatures").expandingTildeInPath
    var recentSigs: [(path: String, date: Date)] = []
    var watcher: DispatchSourceFileSystemObject?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "pencil.and.scribble", accessibilityDescription: "Topaz")
            btn.image?.size = NSSize(width: 18, height: 18)
            btn.image?.isTemplate = true
        }
        try? FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)
        refreshRecent(); watchDir()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkConn() }
        startDaemon()
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()

        // Status
        let st = isConnected ? "● Pad Connected" : "○ Pad Disconnected"
        let si = NSMenuItem(title: st, action: nil, keyEquivalent: ""); si.isEnabled = false; menu.addItem(si)
        let dr = daemon?.running ?? false
        let di = NSMenuItem(title: dr ? "Daemon: Running" : "Daemon: Stopped", action: nil, keyEquivalent: "")
        di.isEnabled = false; menu.addItem(di)
        menu.addItem(.separator())

        // Daemon control
        if dr {
            menu.addItem(NSMenuItem(title: "Stop Daemon", action: #selector(stopDaemon), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Start Daemon", action: #selector(startDaemon), keyEquivalent: ""))
        }

        // Quick actions
        menu.addItem(.separator())
        let captureItem = NSMenuItem(title: "Capture Signature Now...", action: #selector(captureNow), keyEquivalent: "s")
        captureItem.isEnabled = isConnected
        menu.addItem(captureItem)

        let testItem = NSMenuItem(title: "Test Connection", action: #selector(testConnection), keyEquivalent: "t")
        testItem.isEnabled = isConnected
        menu.addItem(testItem)

        // Stabilization submenu
        let stabMenu = NSMenu()
        for (title, tag) in [("Off", 0), ("Light", 1), ("Medium", 2), ("Heavy", 3)] {
            let item = NSMenuItem(title: title, action: #selector(setStabilization(_:)), keyEquivalent: "")
            item.tag = tag
            item.state = (daemon?.stabilize ?? 0) == tag ? .on : .off
            stabMenu.addItem(item)
        }
        let stabItem = NSMenuItem(title: "Stabilization", action: nil, keyEquivalent: "")
        stabItem.submenu = stabMenu
        menu.addItem(stabItem)

        // Recent signatures
        menu.addItem(.separator())
        let rh = NSMenuItem(title: "Recent Signatures", action: nil, keyEquivalent: ""); rh.isEnabled = false; menu.addItem(rh)
        if recentSigs.isEmpty {
            let e = NSMenuItem(title: "  (none)", action: nil, keyEquivalent: ""); e.isEnabled = false; menu.addItem(e)
        } else {
            for (i, s) in recentSigs.prefix(5).enumerated() {
                let name = (s.path as NSString).lastPathComponent
                let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss"
                let item = NSMenuItem(title: "  \(fmt.string(from: s.date))  \(name)", action: #selector(openSig(_:)), keyEquivalent: "")
                item.tag = i; item.representedObject = s.path as NSString
                if let img = NSImage(contentsOfFile: s.path) {
                    let thumb = NSImage(size: NSSize(width: 80, height: 24))
                    thumb.lockFocus(); img.draw(in: NSRect(x: 0, y: 0, width: 80, height: 24)); thumb.unlockFocus()
                    item.image = thumb
                }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Signatures Folder", action: #selector(openFolder), keyEquivalent: "o"))
        if !recentSigs.isEmpty {
            menu.addItem(NSMenuItem(title: "Copy Last to Clipboard", action: #selector(copyLast), keyEquivalent: "c"))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Topaz", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func startDaemon() {
        guard daemon == nil || !daemon!.running else { return }
        let d = TopazDaemon(model: TopazModel.get(TopazModel.defaultName))
        daemon = d
        daemonQueue.async { d.run() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.rebuildMenu() }
    }

    @objc func stopDaemon() {
        daemon?.running = false; daemon = nil; rebuildMenu()
    }

    @objc func captureNow() {
        guard isConnected, let dev = detectDevices().first else {
            sendNotification("Topaz", "No pad connected"); return
        }
        sendNotification("Topaz", "Draw on the pad now... auto-saves after 5s idle")
        let model = TopazModel.get(TopazModel.defaultName)
        let stabilize = daemon?.stabilize ?? 0

        // Stop daemon temporarily to free the port
        let wasRunning = daemon?.running ?? false
        daemon?.running = false

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            if let sig = headlessCapture(device: dev, model: model, timeout: 5, stabilize: stabilize) {
                let dir = self.saveDir
                _ = saveSignature(sig, dir: dir)
                sendNotification("Signature Captured",
                                 "\(sig.totalPoints) points, \(sig.strokes.count) strokes — copied to clipboard", sound: true)
            } else {
                sendNotification("Topaz", "No signature captured")
            }
            DispatchQueue.main.async {
                if wasRunning { self.startDaemon() }
            }
        }
    }

    @objc func testConnection() {
        guard let dev = detectDevices().first else {
            sendNotification("Topaz", "No pad connected"); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let port = try? SerialPort(path: dev, baud: 19200) else {
                sendNotification("Topaz", "Cannot open device"); return
            }
            usleep(300_000); port.flush()
            let reader = PacketReader(port: port)
            let start = Date(); var count = 0
            while Date().timeIntervalSince(start) < 3 {
                if reader.next() != nil { count += 1 }
            }
            port.close()
            let msg = count > 0 ? "Connection OK: \(count) packets in 3s" : "No data — touch the pen to pad"
            sendNotification("Topaz Test", msg, sound: count > 0)
        }
    }

    @objc func setStabilization(_ sender: NSMenuItem) {
        let wasRunning = daemon?.running ?? false
        daemon?.running = false
        daemon = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let d = TopazDaemon(model: TopazModel.get(TopazModel.defaultName), stabilize: sender.tag)
            self.daemon = d
            if wasRunning {
                self.daemonQueue.async { d.run() }
            }
            self.rebuildMenu()
        }
    }

    @objc func openSig(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    @objc func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: saveDir)) }

    @objc func copyLast() {
        guard let last = recentSigs.first, let img = NSImage(contentsOfFile: last.path) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img])
        sendNotification("Topaz", "Signature copied to clipboard")
    }

    @objc func quit() { stopDaemon(); NSApp.terminate(nil) }

    func checkConn() {
        let new = !detectDevices().isEmpty
        if new != isConnected {
            isConnected = new
            if let btn = statusItem.button {
                btn.image = NSImage(systemSymbolName: isConnected ? "pencil.and.scribble" : "pencil.slash", accessibilityDescription: nil)
                btn.image?.size = NSSize(width: 18, height: 18); btn.image?.isTemplate = true
            }
            rebuildMenu()
        }
    }

    func watchDir() {
        let fd = Darwin.open(saveDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.refreshRecent(); self?.rebuildMenu() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume(); watcher = src
    }

    func refreshRecent() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: saveDir) else { return }
        recentSigs = files.filter { $0.hasSuffix(".png") }.compactMap { name -> (String, Date)? in
            let path = "\(saveDir)/\(name)"
            guard let a = try? fm.attributesOfItem(atPath: path), let d = a[.modificationDate] as? Date else { return nil }
            return (path, d)
        }.sorted { $0.1 > $1.1 }
    }
}

// MARK: - Compare

func compareSignatures(_ path1: String, _ path2: String, overlay: Bool) {
    guard let s1 = SignatureData.load(from: path1), let s2 = SignatureData.load(from: path2) else {
        print("Error loading signature files"); return
    }
    let termW = Int(ProcessInfo.processInfo.environment["COLUMNS"] ?? "80") ?? 80
    let termH = 20
    if overlay { printOverlay(s1, s2, cols: termW - 2, rows: termH) }
    else { printSideBySide(s1, s2, cols: (termW - 3) / 2, rows: termH) }
}

func renderBraille(_ sig: SignatureData, cols: Int, rows: Int) -> [UInt8] {
    let dotW = cols * 2, dotH = rows * 4
    var grid = [UInt8](repeating: 0, count: cols * rows)
    let DM: [(Int, Int, UInt8)] = [(0,0,0x01),(0,1,0x02),(0,2,0x04),(0,3,0x40),(1,0,0x08),(1,1,0x10),(1,2,0x20),(1,3,0x80)]
    let allX = sig.strokes.flatMap { $0.map { $0.0 } }
    let allY = sig.strokes.flatMap { $0.map { $0.1 } }
    let maxX = allX.max() ?? 100, maxY = allY.max() ?? 100
    for stroke in sig.strokes {
        for j in 1..<stroke.count {
            var (x0, y0) = (Int(stroke[j-1].0 / maxX * Double(dotW-1)), Int(stroke[j-1].1 / maxY * Double(dotH-1)))
            let (x1, y1) = (Int(stroke[j].0 / maxX * Double(dotW-1)), Int(stroke[j].1 / maxY * Double(dotH-1)))
            let ddx = abs(x1-x0), ddy = abs(y1-y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
            var err = ddx - ddy
            while true {
                let px = max(0, min(dotW-1, x0)), py = max(0, min(dotH-1, y0))
                let idx = (py/4) * cols + (px/2)
                if idx >= 0 && idx < grid.count {
                    for (mx, my, bit) in DM { if mx == px%2 && my == py%4 { grid[idx] |= bit; break } }
                }
                if x0 == x1 && y0 == y1 { break }
                let e2 = 2 * err
                if e2 > -ddy { err -= ddy; x0 += sx }
                if e2 < ddx { err += ddx; y0 += sy }
            }
        }
    }
    return grid
}

func printSideBySide(_ s1: SignatureData, _ s2: SignatureData, cols: Int, rows: Int) {
    let g1 = renderBraille(s1, cols: cols, rows: rows), g2 = renderBraille(s2, cols: cols, rows: rows)
    let B = 0x2800
    print(String(repeating: "-", count: cols) + "-+-" + String(repeating: "-", count: cols))
    for row in 0..<rows {
        var left = "", right = ""
        for col in 0..<cols {
            let v1 = g1[row*cols+col]; left += v1 > 0 ? String(UnicodeScalar(B+Int(v1))!) : " "
            let v2 = g2[row*cols+col]; right += v2 > 0 ? String(UnicodeScalar(B+Int(v2))!) : " "
        }
        print(left + " | " + right)
    }
}

func printOverlay(_ s1: SignatureData, _ s2: SignatureData, cols: Int, rows: Int) {
    let g1 = renderBraille(s1, cols: cols, rows: rows), g2 = renderBraille(s2, cols: cols, rows: rows)
    let B = 0x2800
    for row in 0..<rows {
        var line = ""
        for col in 0..<cols {
            let v1 = g1[row*cols+col], v2 = g2[row*cols+col]
            if v1 > 0 && v2 > 0 { line += "\u{1b}[1;37m\(String(UnicodeScalar(B+Int(v1|v2))!))\u{1b}[0m" }
            else if v1 > 0 { line += "\u{1b}[34m\(String(UnicodeScalar(B+Int(v1))!))\u{1b}[0m" }
            else if v2 > 0 { line += "\u{1b}[31m\(String(UnicodeScalar(B+Int(v2))!))\u{1b}[0m" }
            else { line += " " }
        }
        print(line)
    }
    print("\n\u{1b}[34mSig 1\u{1b}[0m  |  \u{1b}[31mSig 2\u{1b}[0m  |  \u{1b}[1;37mOverlap\u{1b}[0m")
}

// MARK: - CLI

func printUsage() {
    print("""
    Topaz Signature Pad Tool

    USAGE: topaz <command> [options]

    COMMANDS:
      (no args)        Launch menu bar app
      capture          Capture a signature (CLI)
      monitor          Debug raw packets
      test             Quick connectivity test
      info             Show tablet info
      devices          List connected pads
      compare <a> <b>  Compare two signature files
      convert <in> <out> Convert between formats
      daemon run       Run background daemon
      daemon install   Install as login item
      daemon uninstall Remove login item
      menubar          Launch menu bar app

    OPTIONS:
      -d, --device <path>    Serial device
      -m, --model <name>     Tablet model (default: SignatureGem1X5)
      -o, --output <file>    Output filename
      -f, --format <fmt>     svg, png, jpeg, tiff, pdf
      -t, --timeout <secs>   Inactivity timeout (default: 10)
      --ink-color <hex>      Ink color (default: #000000)
      --ink-width <n>        Stroke width (default: 2.0)
      --bg-color <color>     Background (default: white)
      --stabilize <0-3>      Stroke stabilization level (0=off)
      --overlay              Overlay mode for compare
    """)
}

func main() {
    let args = CommandLine.arguments
    if args.count < 2 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MenuBarApp()
        app.delegate = delegate
        app.run()
        return
    }

    let command = args[1]
    var device = defaultDevice, modelName = TopazModel.defaultName
    var output: String? = nil, format = "svg"
    var timeout = 10, stabilize = 0
    var inkColor = "#000000", inkWidth = 2.0, bgColor = "white"
    var overlay = false, filterSize: Int? = nil
    var extraArgs: [String] = []

    var i = 2
    while i < args.count {
        switch args[i] {
        case "-d", "--device": i += 1; if i < args.count { device = args[i] }
        case "-m", "--model": i += 1; if i < args.count { modelName = args[i] }
        case "-o", "--output": i += 1; if i < args.count { output = args[i] }
        case "-f", "--format": i += 1; if i < args.count { format = args[i] }
        case "-t", "--timeout": i += 1; if i < args.count { timeout = Int(args[i]) ?? 10 }
        case "--ink-color": i += 1; if i < args.count { inkColor = args[i] }
        case "--ink-width": i += 1; if i < args.count { inkWidth = Double(args[i]) ?? 2.0 }
        case "--bg-color": i += 1; if i < args.count { bgColor = args[i] }
        case "--filter": i += 1; if i < args.count { filterSize = Int(args[i]) }
        case "--stabilize": i += 1; if i < args.count { stabilize = Int(args[i]) ?? 0 }
        case "--overlay": overlay = true
        case "-h", "--help": printUsage(); return
        default: extraArgs.append(args[i])
        }
        i += 1
    }
    let model = TopazModel.get(modelName)

    switch command {
    case "capture":
        _ = cliCapture(device: device, model: model, output: output, format: format,
                        timeout: timeout, inkColor: inkColor, inkWidth: inkWidth,
                        bgColor: bgColor, filterSize: filterSize, stabilize: stabilize)
    case "monitor":
        guard let port = try? SerialPort(path: device, baud: model.baud, dataBits: model.format == 1 ? 7 : 8) else { print("Cannot open device"); return }
        usleep(300_000); port.flush(); print("Monitoring. Ctrl+C to stop.\n")
        captureRunning = true; signal(SIGINT, signalHandler)
        let reader = PacketReader(port: port, format: model.format); var count = 0
        while captureRunning {
            if let pkt = reader.next() {
                count += 1
                if pkt.isPressureData { print("  \(count): <Pressure: \(pkt.pressure)>") }
                else if pkt.isInfoData { print("  \(count): <Model:\(pkt.modelNumber) Serial:\(pkt.serialNumber)>") }
                else { print("  \(count): <Pen \(pkt.penDown ? "DOWN" : "UP") x=\(pkt.rawX) y=\(pkt.rawY)>") }
                if count > 10000 { break }
            }
        }
        port.close(); print("\n\(count) packets.")
    case "test":
        guard let port = try? SerialPort(path: device, baud: model.baud, dataBits: model.format == 1 ? 7 : 8) else { print("Cannot open device"); return }
        usleep(300_000); port.flush(); print("Listening 5s... touch the pad!")
        let reader = PacketReader(port: port, format: model.format); let start = Date(); var count = 0
        while Date().timeIntervalSince(start) < 5 {
            if let pkt = reader.next() { count += 1; if count <= 20 { print("  <Pen \(pkt.penDown ? "DOWN" : "UP") x=\(pkt.rawX) y=\(pkt.rawY)>") } }
        }
        port.close(); print(count > 0 ? "\nSUCCESS: \(count) packets!" : "\nNo packets.")
    case "info":
        print("Device:     \(device)\nModel:      \(model.name)\nBaud:       \(model.baud)")
        print("Format:     \(model.format == 0 ? "8O1" : "7O1")\nResolution: \(model.resolution) dpi")
        print("Coords:     X[\(model.xStart)-\(model.xStop)] Y[\(model.yStart)-\(model.yStop)]")
        print("Logical:    \(model.logicalX) x \(model.logicalY)")
    case "devices":
        let devs = detectDevices()
        if devs.isEmpty { print("No Topaz devices found.") }
        else { print("Found \(devs.count):"); for d in devs { print("  \(d)") } }
    case "compare":
        guard extraArgs.count >= 2 else { print("Usage: topaz compare <f1> <f2> [--overlay]"); return }
        compareSignatures(extraArgs[0], extraArgs[1], overlay: overlay)
    case "convert":
        guard extraArgs.count >= 2 else { print("Usage: topaz convert <in> <out>"); return }
        guard let sig = SignatureData.load(from: extraArgs[0]) else { print("Cannot load \(extraArgs[0])"); return }
        let dst = extraArgs[1]; let ext = (dst as NSString).pathExtension.lowercased()
        switch ext {
        case "json": sig.save(to: dst)
        case "sigstring": try? sig.toSigString().write(toFile: dst, atomically: true, encoding: .utf8); print("Saved: \(dst)")
        case "svg": exportSVG(sig, to: dst, inkColor: inkColor, inkWidth: inkWidth, bgColor: bgColor)
        case "pdf": exportPDF(sig, to: dst, inkColor: inkColor, inkWidth: inkWidth)
        default: exportImage(sig, to: dst, format: ext, inkColor: inkColor, inkWidth: inkWidth, bgColor: bgColor)
        }
    case "daemon":
        if extraArgs.first == "install" { installLaunchAgent() }
        else if extraArgs.first == "uninstall" { uninstallLaunchAgent() }
        else { TopazDaemon(model: model, device: device == defaultDevice ? nil : device, stabilize: stabilize).run() }
    case "menubar":
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = MenuBarApp(); app.delegate = delegate; app.run()
    default: printUsage()
    }
}

main()
