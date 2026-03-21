// TopazKit.swift — Topaz Signature Pad Library for Swift
//
// Import this single file into your project to communicate with Topaz pads.
// No dependencies beyond Foundation and Darwin. No AppKit required for core functionality.
//
// Usage:
//   let pad = try TopazKit.open()
//   let sig = pad.capture(timeout: 10)
//   let svg = sig.toSVG()

import Foundation
import Darwin

// MARK: - Public API

public enum TopazKit {

    /// Open a connection to a Topaz pad. Auto-detects device if path is nil.
    public static func open(device: String? = nil, model: String = "SignatureGem1X5") throws -> TopazConnection {
        let m = TopazModels.get(model)
        let path = device ?? detectDevices().first
        guard let path else { throw TopazError.noDevice }
        return try TopazConnection(path: path, model: m)
    }

    /// List connected Topaz devices.
    public static func detectDevices() -> [String] {
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
}

public enum TopazError: Error, CustomStringConvertible {
    case noDevice
    case cannotOpen(String)
    case noData

    public var description: String {
        switch self {
        case .noDevice: return "No Topaz device found"
        case .cannotOpen(let msg): return "Cannot open device: \(msg)"
        case .noData: return "No signature data captured"
        }
    }
}

// MARK: - Models

public struct TopazModels {
    public let name: String
    public let xStart, xStop, yStart, yStop: Int
    public let logicalX, logicalY: Int
    public let baud: Int
    public let resolution, timingAdvance, filterPoints, format: Int

    public static let all: [String: TopazModels] = [
        "SignatureGem1X5":    TopazModels(name: "SignatureGem1X5",    xStart: 400, xStop: 2400, yStart: 350, yStop:  950, logicalX: 2000, logicalY:  600, baud: 19200,  resolution: 410, timingAdvance: 4, filterPoints: 4, format: 0),
        "SignatureGemLCD1X5": TopazModels(name: "SignatureGemLCD1X5", xStart: 400, xStop: 2400, yStart: 350, yStop: 1250, logicalX: 2000, logicalY:  900, baud: 19200,  resolution: 410, timingAdvance: 4, filterPoints: 4, format: 1),
        "SignatureGem4X5":    TopazModels(name: "SignatureGem4X5",    xStart: 500, xStop: 2650, yStart: 700, yStop: 2100, logicalX: 2150, logicalY: 1400, baud: 19200,  resolution: 410, timingAdvance: 4, filterPoints: 4, format: 0),
        "SigLite1X5":         TopazModels(name: "SigLite1X5",         xStart: 500, xStop: 2650, yStart: 700, yStop: 2100, logicalX: 2150, logicalY: 1400, baud: 19200,  resolution: 410, timingAdvance: 2, filterPoints: 2, format: 0),
        "SigLiteLCD1X5":      TopazModels(name: "SigLiteLCD1X5",      xStart: 400, xStop: 2400, yStart: 350, yStop: 1050, logicalX: 2000, logicalY:  700, baud: 19200,  resolution: 410, timingAdvance: 0, filterPoints: 4, format: 0),
        "SigLiteLCD4X5":      TopazModels(name: "SigLiteLCD4X5",      xStart: 500, xStop: 2600, yStart: 500, yStop: 2100, logicalX: 2100, logicalY: 1600, baud: 38400,  resolution: 410, timingAdvance: 4, filterPoints: 4, format: 0),
        "ClipGem":            TopazModels(name: "ClipGem",            xStart: 485, xStop: 2800, yStart: 170, yStop: 3200, logicalX: 2315, logicalY: 3030, baud: 9600,   resolution: 275, timingAdvance: 1, filterPoints: 2, format: 0),
        "SigGemColor57":      TopazModels(name: "SigGemColor57",      xStart: 300, xStop: 2370, yStart: 350, yStop: 1950, logicalX: 2070, logicalY: 1600, baud: 115200, resolution: 410, timingAdvance: 4, filterPoints: 4, format: 0),
    ]

    public static func get(_ name: String) -> TopazModels {
        return all[name] ?? all["SignatureGem1X5"]!
    }

    public func scaleCoords(rawX: Int, rawY: Int) -> (Double, Double) {
        var x = Double(rawX - xStart) * Double(logicalX) / Double(xStop - xStart)
        var y = Double(rawY - yStart) * Double(logicalY) / Double(yStop - yStart)
        x = max(0, min(Double(logicalX), x))
        y = max(0, min(Double(logicalY), y))
        return (x, y)
    }
}

// MARK: - Packet

public struct TopazPacket {
    public let rawX, rawY: Int
    public let penDown, penNear: Bool
    public let packetType: Int
    public let pressure: Int
    public let modelNumber, serialNumber: Int
    public let timestamp: TimeInterval

    public var isPenData: Bool { packetType == 0 || packetType == 1 || packetType == 4 }
    public var isPressureData: Bool { packetType == 7 }
    public var isInfoData: Bool { packetType == 2 }
    public var isBad: Bool { rawX == 0x0FFF && rawY == 0x0FFF }

    public init(bytes: [UInt8], fmt: Int = 0) {
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
        pressure = packetType == 7 ? (Int(bytes[4] & 0x07) << 7) | Int(bytes[3] & 0x7F) : 0
        if packetType == 2 {
            let d0 = Int(bytes[1] & 0x7F) | (Int(bytes[2] & 0x7F) << 7)
            let d1 = Int(bytes[3] & 0x7F) | (Int(bytes[4] & 0x7F) << 7)
            modelNumber = (d0 & 0xFC) >> 2
            serialNumber = ((d0 & 0x03) << 16) | d1
        } else { modelNumber = 0; serialNumber = 0 }
    }
}

// MARK: - Signature

public class TopazSignature {
    public let model: TopazModels
    public var strokes: [[(Double, Double)]] = []
    public var pressures: [[Int]] = []
    public var timestamps: [[TimeInterval]] = []

    public init(model: TopazModels = TopazModels.get("SignatureGem1X5")) { self.model = model }

    public var totalPoints: Int { strokes.reduce(0) { $0 + $1.count } }
    public var isEmpty: Bool { strokes.isEmpty }

    public func addStroke(_ points: [(Double, Double)], pressures p: [Int] = [], timestamps t: [TimeInterval] = []) {
        guard points.count >= 2 else { return }
        strokes.append(points)
        pressures.append(p.isEmpty ? Array(repeating: 0, count: points.count) : p)
        timestamps.append(t.isEmpty ? Array(repeating: 0.0, count: points.count) : t)
    }

    /// Export to SVG string (auto-cropped, transparent).
    public func toSVG(inkColor: String = "#000000", inkWidth: Double = 2, padding: Double = 10) -> String {
        let b = bounds(inkWidth: inkWidth)
        let w = Int(b.maxX - b.minX + padding * 2)
        let h = Int(b.maxY - b.minY + padding * 2)
        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(w) \(h)\" width=\"\(w)\" height=\"\(h)\">"
        for stroke in strokes {
            guard stroke.count >= 2 else { continue }
            let pts = stroke.map {
                "\(String(format: "%.1f", $0.0 - b.minX + padding)),\(String(format: "%.1f", $0.1 - b.minY + padding))"
            }.joined(separator: " ")
            svg += "\n  <polyline points=\"\(pts)\" fill=\"none\" stroke=\"\(inkColor)\" stroke-width=\"\(inkWidth)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }
        svg += "\n</svg>"
        return svg
    }

    /// Export to SigString format (Topaz interchange).
    public func toSigString() -> String {
        var lines: [String] = ["\(totalPoints)", "\(strokes.count)"]
        for stroke in strokes { for (x, y) in stroke { lines.append("\(Int(x)) \(Int(y))") } }
        var cum = 0
        for stroke in strokes { cum += stroke.count - 1; lines.append("\(cum)") }
        let raw = lines.joined(separator: "\r\n")
        return raw.data(using: .ascii)!.map { String(format: "%02X", $0) }.joined()
    }

    /// Export to JSON.
    public func toJSON() -> Data {
        let dict: [String: Any] = [
            "model": model.name,
            "strokes": strokes.map { $0.map { [$0.0, $0.1] } },
            "pressures": pressures,
            "total_points": totalPoints,
            "total_strokes": strokes.count,
        ]
        return try! JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
    }

    public func bounds(inkWidth: Double = 2) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty else { return (0, 0, 100, 100) }
        let pad = inkWidth * 2
        return (
            all.map { $0.0 }.min()! - pad, all.map { $0.1 }.min()! - pad,
            all.map { $0.0 }.max()! + pad, all.map { $0.1 }.max()! + pad
        )
    }
}

// MARK: - Connection

public class TopazConnection {
    public let model: TopazModels
    public let path: String
    private let fd: Int32
    private let reader: TopazPacketReader

    public init(path: String, model: TopazModels) throws {
        self.path = path
        self.model = model

        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            throw TopazError.cannotOpen(String(cString: strerror(errno)))
        }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        _ = ioctl(fd, TIOCEXCL)

        var options = termios()
        tcgetattr(fd, &options)
        let speed: speed_t
        switch model.baud {
        case 9600: speed = speed_t(B9600)
        case 38400: speed = speed_t(B38400)
        case 115200: speed = speed_t(B115200)
        default: speed = speed_t(B19200)
        }
        cfsetispeed(&options, speed); cfsetospeed(&options, speed)
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(model.format == 1 ? CS7 : CS8)
        options.c_cflag |= tcflag_t(PARENB | PARODD)
        options.c_cflag &= ~tcflag_t(CSTOPB)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY | ISTRIP)
        options.c_iflag |= tcflag_t(INPCK)
        options.c_iflag &= ~tcflag_t(ICRNL | INLCR | IGNCR)
        options.c_oflag &= ~tcflag_t(OPOST)
        withUnsafeMutableBytes(of: &options.c_cc) { $0[Int(VMIN)] = 0; $0[Int(VTIME)] = 1 }
        tcsetattr(fd, TCSANOW, &options)
        tcflush(fd, TCIOFLUSH)

        reader = TopazPacketReader(fd: fd, format: model.format)
        usleep(300_000)
        tcflush(fd, TCIFLUSH)
    }

    deinit { close() }

    public func close() { Darwin.close(fd) }

    /// Read the next packet. Returns nil on timeout.
    public func nextPacket() -> TopazPacket? { reader.next() }

    /// Blocking capture. Returns when pen is idle for `timeout` seconds.
    public func capture(timeout: TimeInterval = 10, minPoints: Int = 5) -> TopazSignature? {
        let sig = TopazSignature(model: model)
        var pf = PointFilter(size: model.filterPoints)
        var currentStroke: [(Double, Double)] = []
        var currentPressures: [Int] = []
        var currentTimestamps: [TimeInterval] = []
        var penWasDown = false
        var currentPressure = 0
        var lastActivity = ProcessInfo.processInfo.systemUptime
        var totalPoints = 0

        while true {
            if let packet = nextPacket() {
                if packet.isPressureData { currentPressure = packet.pressure; continue }
                guard packet.isPenData else { continue }
                lastActivity = ProcessInfo.processInfo.systemUptime

                if packet.penDown {
                    let (rx, ry) = model.scaleCoords(rawX: packet.rawX, rawY: packet.rawY)
                    let (fx, fy) = pf.add(Int(rx), Int(ry))
                    if !penWasDown {
                        currentStroke = [(Double(fx), Double(fy))]
                        currentPressures = [currentPressure]
                        currentTimestamps = [packet.timestamp]
                        penWasDown = true
                    } else {
                        currentStroke.append((Double(fx), Double(fy)))
                        currentPressures.append(currentPressure)
                        currentTimestamps.append(packet.timestamp)
                    }
                    totalPoints += 1
                } else if penWasDown {
                    sig.addStroke(currentStroke, pressures: currentPressures, timestamps: currentTimestamps)
                    currentStroke = []; currentPressures = []; currentTimestamps = []
                    penWasDown = false; pf.clear()
                    lastActivity = ProcessInfo.processInfo.systemUptime
                }
            } else {
                if totalPoints >= minPoints && !penWasDown &&
                   ProcessInfo.processInfo.systemUptime - lastActivity > timeout { break }
            }
        }
        if penWasDown && currentStroke.count >= 2 {
            sig.addStroke(currentStroke, pressures: currentPressures, timestamps: currentTimestamps)
        }
        return sig.totalPoints >= minPoints ? sig : nil
    }

    /// Stream packets via callback. Return false from callback to stop.
    public func stream(_ handler: (TopazPacket) -> Bool) {
        while true {
            if let packet = nextPacket() {
                if !handler(packet) { break }
            }
        }
    }
}

// MARK: - Internal

private struct PointFilter {
    let size: Int
    var xBuf: [Int] = [], yBuf: [Int] = []
    init(size: Int) { self.size = size }
    mutating func add(_ x: Int, _ y: Int) -> (Int, Int) {
        xBuf.append(x); yBuf.append(y)
        if xBuf.count > size { xBuf.removeFirst() }
        if yBuf.count > size { yBuf.removeFirst() }
        return (xBuf.reduce(0, +) / xBuf.count, yBuf.reduce(0, +) / yBuf.count)
    }
    mutating func clear() { xBuf.removeAll(); yBuf.removeAll() }
}

private class TopazPacketReader {
    let fd: Int32, format: Int
    var state = 0, buf: [UInt8] = []
    init(fd: Int32, format: Int) { self.fd = fd; self.format = format }

    func next() -> TopazPacket? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let n = Darwin.read(fd, &buffer, 64)
        guard n > 0 else { return nil }
        for i in 0..<n {
            let byte = buffer[i]
            let start = format == 0 ? (byte & 0x80) != 0 : (byte & 0x70) != 0x30
            switch state {
            case 0: if start { buf = [byte]; state = 1 }
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
                        if !bad { let pkt = TopazPacket(bytes: buf, fmt: format); buf = []; if !pkt.isBad { return pkt } }
                        buf = []
                    }
                }
            default: state = 0
            }
        }
        return nil
    }
}
