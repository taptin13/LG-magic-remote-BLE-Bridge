import Foundation
import Combine
import SwiftUI

/// USB serial tới ESP32 MR-Dongle — gửi CFG, đọc log/status.
@MainActor
final class SerialPort: ObservableObject {
    enum State: String { case disconnected, connecting, open, failed }

    @Published private(set) var ports: [String] = []
    @Published var selectedPort = ""

    var portBinding: Binding<String> {
        Binding(
            get: { [weak self] in self?.selectedPort ?? "" },
            set: { [weak self] in self?.selectedPort = $0 }
        )
    }
    @Published private(set) var state: State = .disconnected
    @Published private(set) var lastLine = ""

    var onLine: ((String) -> Void)?
    var onLog: ((LogLevel, String) -> Void)?

    private var fd: Int32 = -1
    private var readTask: Task<Void, Never>?
    private var lineBuffer = Data()

    func refreshPorts() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let cu = names
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && !$0.contains("debug-console") }
            .map { "/dev/\($0)" }
            .sorted()
        ports = cu
        if selectedPort.isEmpty || !cu.contains(selectedPort) {
            selectedPort = cu.first(where: {
                $0.contains("wchusbserial") || $0.contains("usbserial") || $0.contains("SLAB") || $0.contains("usbmodem")
            }) ?? cu.first ?? ""
        }
    }

    func connect() {
        guard state != .open, !selectedPort.isEmpty else { return }
        disconnect()
        state = .connecting
        onLog?(.info, "Mở \(selectedPort) @ 115200")

        let handle = open(selectedPort, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            state = .failed
            onLog?(.error, "open failed: \(String(cString: strerror(errno)))")
            return
        }

        var tty = termios()
        guard tcgetattr(handle, &tty) == 0 else {
            close(handle)
            state = .failed
            onLog?(.error, "tcgetattr failed")
            return
        }
        cfmakeraw(&tty)
        cfsetspeed(&tty, speed_t(B115200))
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tty.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
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
        onLog?(.ok, "Serial mở — gửi CFG GET")

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
        lineBuffer.removeAll()
    }

    func send(_ line: String) {
        guard state == .open, fd >= 0 else { return }
        var payload = line.trimmingCharacters(in: .whitespacesAndNewlines)
        payload += "\r\n"
        guard let data = payload.data(using: .utf8) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = write(fd, base, data.count)
        }
        _ = tcdrain(fd)
        onLog?(.tx, line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func readLoop() async {
        var buf = [UInt8](repeating: 0, count: 2048)
        while !Task.isCancelled {
            let n = fd >= 0 ? read(fd, &buf, buf.count) : -1
            if n > 0 {
                let chunk = Data(buf.prefix(n))
                await MainActor.run { self.consume(chunk) }
            } else if n == 0 || (n < 0 && errno == EAGAIN) {
                try? await Task.sleep(for: .milliseconds(25))
            } else {
                let err = String(cString: strerror(errno))
                await MainActor.run {
                    self.onLog?(.error, "Serial read: \(err)")
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
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else { continue }
            lastLine = line
            onLine?(line)
        }
        if lineBuffer.count > 64_000 { lineBuffer.removeAll() }
    }
}
