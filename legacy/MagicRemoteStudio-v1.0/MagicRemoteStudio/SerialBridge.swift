import Foundation
import Combine

/// Reads ESP32 bridge lines from a USB serial port (`/dev/cu.*`).
/// Protocol:
///   BRIDGE HID <reportIdHex> <handleHex> <payloadHexCompact>
///   BRIDGE STATUS <token>
///   BRIDGE UP <seconds>
@MainActor
final class SerialBridge: ObservableObject {
    enum ConnectionState: String {
        case disconnected, connecting, open, failed
    }

    @Published private(set) var ports: [String] = []
    @Published var selectedPort: String = ""
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var bridgeStatus = "idle"
    @Published private(set) var linkSeconds: Double = 0
    @Published private(set) var lastHIDLine = ""
    @Published private(set) var hidPacketCount = 0
    @Published private(set) var recentReports: [HIDFDReport] = []

    var onLog: ((LogLevel, String) -> Void)?
    var onHID: ((UInt8, Data) -> Void)?
    var onFDReport: ((HIDFDReport) -> Void)?

    private var fd: Int32 = -1
    private var readTask: Task<Void, Never>?
    private var lineBuffer = Data()
    private let analyzer = ProtocolAnalyzer()
    /// Edge-trigger button logs (remote spam ~50 Hz while held).
    private var lastLoggedButton: UInt16 = 0xFFFF
    private var lastUIPublish = Date.distantPast
    private var pendingHIDCount = 0

    func refreshPorts() {
        let fm = FileManager.default
        let dev = "/dev"
        let names = (try? fm.contentsOfDirectory(atPath: dev)) ?? []
        let cu = names
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && !$0.contains("debug-console") }
            .map { "/dev/\($0)" }
            .sorted()
        ports = cu
        if selectedPort.isEmpty || !cu.contains(selectedPort) {
            selectedPort = cu.first(where: { $0.contains("wchusbserial") || $0.contains("usbserial") || $0.contains("SLAB") || $0.contains("usbmodem") })
                ?? cu.first
                ?? ""
        }
    }

    func connect() {
        guard state != .open, !selectedPort.isEmpty else { return }
        disconnect()
        state = .connecting
        onLog?(.info, "Opening \(selectedPort) @ 115200")

        let handle = open(selectedPort, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            state = .failed
            onLog?(.error, "open(\(selectedPort)) failed: \(String(cString: strerror(errno)))")
            return
        }

        var tty = termios()
        if tcgetattr(handle, &tty) != 0 {
            close(handle)
            state = .failed
            onLog?(.error, "tcgetattr failed")
            return
        }

        cfmakeraw(&tty)
        cfsetspeed(&tty, speed_t(B115200))
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(PARENB)
        tty.c_cflag &= ~tcflag_t(CSTOPB)
        tty.c_cflag &= ~tcflag_t(CSIZE)
        tty.c_cflag |= tcflag_t(CS8)
        withUnsafeMutablePointer(to: &tty.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 1
            }
        }

        _ = tcsetattr(handle, TCSANOW, &tty)
        _ = tcflush(handle, TCIOFLUSH)
        let flags = fcntl(handle, F_GETFL)
        _ = fcntl(handle, F_SETFL, flags | O_NONBLOCK)

        fd = handle
        state = .open
        bridgeStatus = "open"
        onLog?(.matrix, "Serial bridge open — waiting for BRIDGE lines from ESP32")

        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func disconnect() {
        readTask?.cancel()
        readTask = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        state = .disconnected
        bridgeStatus = "idle"
        lineBuffer.removeAll()
    }

    func clearReports() {
        recentReports.removeAll()
        hidPacketCount = 0
        pendingHIDCount = 0
        lastHIDLine = ""
    }

    private func readLoop() async {
        var buf = [UInt8](repeating: 0, count: 2048)
        while !Task.isCancelled {
            let n: Int
            if fd >= 0 {
                n = read(fd, &buf, buf.count)
            } else {
                n = -1
            }

            if n > 0 {
                let chunk = Data(buf.prefix(n))
                await MainActor.run { self.consume(chunk) }
            } else if n == 0 || (n < 0 && errno == EAGAIN) {
                try? await Task.sleep(for: .milliseconds(20))
            } else {
                let err = String(cString: strerror(errno))
                await MainActor.run {
                    self.onLog?(.error, "Serial read error: \(err)")
                    self.disconnect()
                }
                return
            }
        }
    }

    private func consume(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            var lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            if lineData.last == 0x0D { lineData.removeLast() }
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handleLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // Cap runaway buffer
        if lineBuffer.count > 64_000 { lineBuffer.removeAll() }
    }

    private func handleLine(_ line: String) {
        guard !line.isEmpty else { return }

        // Recover rare Serial interleave: "...hexBRIDGE UP 15.0"
        if let r = line.range(of: "BRIDGE UP "), r.lowerBound > line.startIndex {
            let before = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let after = String(line[r.lowerBound...])
            if !before.isEmpty { handleLine(before) }
            handleLine(after)
            return
        }

        if line.hasPrefix("BRIDGE HID ") {
            parseHID(line)
            return
        }
        if line.hasPrefix("BRIDGE STATUS ") {
            bridgeStatus = String(line.dropFirst("BRIDGE STATUS ".count))
            onLog?(.info, line)
            return
        }
        if line.hasPrefix("BRIDGE UP ") {
            if let v = Double(line.dropFirst("BRIDGE UP ".count)) {
                linkSeconds = v
            }
            return
        }

        // Pass through interesting ESP32 diagnostics sparsely
        if line.hasPrefix("[SMP]") || line.hasPrefix("[GAP]") || line.hasPrefix("[GATT] summary")
            || line.hasPrefix("[GATT] HID Report characteristics")
            || line.hasPrefix("===") {
            onLog?(.info, line)
        }
    }

    private func parseHID(_ line: String) {
        // BRIDGE HID <id> <handle> <hex>
        let parts = line.split(separator: " ")
        guard parts.count >= 5,
              let reportId = UInt8(parts[2], radix: 16),
              let data = Data(hexText: String(parts[4])),
              !data.isEmpty
        else {
            // Incomplete after interleave recovery — ignore quietly
            return
        }

        lastHIDLine = line
        pendingHIDCount += 1
        onHID?(reportId, data)

        if reportId == 0xFD {
            let decoded = analyzer.decodeMR25GAFD(data)
            // Mapper first — đừng để SwiftUI block chuột
            for r in decoded {
                onFDReport?(r)
            }
            // UI throttle ~8 Hz (full @Published mỗi packet làm chuột giật)
            let now = Date()
            if now.timeIntervalSince(lastUIPublish) >= 0.12 {
                lastUIPublish = now
                hidPacketCount += pendingHIDCount
                pendingHIDCount = 0
                if let last = decoded.last {
                    if recentReports.count >= 40 {
                        recentReports.removeFirst(recentReports.count - 39)
                    }
                    recentReports.append(last)
                }
            }
            if let last = decoded.last, last.buttonCode != lastLoggedButton {
                lastLoggedButton = last.buttonCode
                if last.buttonCode == 0 {
                    onLog?(.rx, "BTN Released")
                } else {
                    onLog?(.rx, "BTN \(last.buttonName) (0x\(String(last.buttonCode, radix: 16))) wheel=\(last.wheel) ctr=\(last.counter)")
                }
            }
        } else {
            hidPacketCount += pendingHIDCount
            pendingHIDCount = 0
            if hidPacketCount <= 20 || hidPacketCount % 50 == 0 {
                onLog?(.rx, String(format: "HID id=0x%02X len=%d", reportId, data.count))
            }
        }
    }
}
