import Foundation

/// Client for usbmuxd, the Mac service behind iTunes/Finder sync. It lets a Mac app open a TCP
/// connection to a port on a phone over the USB cable, with no network involved.
enum UsbMux {
    private static let socketPath = "/var/run/usbmuxd"
    private static let headerSize = 16
    private static let plistMessage: UInt32 = 8

    static func openSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            _ = socketPath.withCString { strncpy(raw.bindMemory(to: CChar.self).baseAddress!, $0, capacity - 1) }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func send(_ fd: Int32, _ message: [String: Any]) -> Bool {
        var body = message
        body["ClientVersionString"] = "i7Companion"
        body["ProgName"] = "i7Companion"
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0) else { return false }

        var packet = Data()
        for value in [UInt32(headerSize + payload.count), 1, plistMessage, 1] {
            withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) }
        }
        packet.append(payload)
        return packet.withUnsafeBytes { raw -> Bool in
            var done = 0
            while done < raw.count {
                let n = write(fd, raw.baseAddress! + done, raw.count - done)
                if n <= 0 { return false }
                done += n
            }
            return true
        }
    }

    /// Reads exactly one message, so that after a successful Connect the socket holds only tunnel data.
    static func receive(_ fd: Int32) -> [String: Any]? {
        var header = [UInt8](repeating: 0, count: headerSize)
        guard readExactly(fd, &header, headerSize) else { return nil }
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.load(as: UInt32.self)) }
        guard length >= headerSize, length < 1_000_000 else { return nil }
        var body = [UInt8](repeating: 0, count: Int(length) - headerSize)
        guard body.isEmpty || readExactly(fd, &body, body.count) else { return nil }
        return try? PropertyListSerialization.propertyList(from: Data(body), options: [], format: nil) as? [String: Any]
    }

    private static func readExactly(_ fd: Int32, _ buffer: inout [UInt8], _ count: Int) -> Bool {
        buffer.withUnsafeMutableBytes { raw -> Bool in
            var done = 0
            while done < count {
                let n = read(fd, raw.baseAddress! + done, count - done)
                if n > 0 {
                    done += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Opens a tunnel to `port` on a device. Returns the socket, now carrying that connection.
    static func connect(deviceID: Int, port: UInt16) -> Int32? {
        guard let fd = openSocket() else { return nil }
        // usbmuxd wants the port in network byte order, inside a plain plist number.
        let sent = send(fd, ["MessageType": "Connect", "DeviceID": deviceID, "PortNumber": Int(port.bigEndian)])
        guard sent, let reply = receive(fd), reply["Number"] as? Int == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}

/// Keeps a live list of phones on USB and tries to reach the app on each. Only a phone that's
/// actually running it accepts, so your other iPhone being plugged in does no harm.
final class PhoneLink {
    /// Called on the main thread.
    var onConnected: ((WireConnection) -> Void)?
    var onDisconnected: (() -> Void)?

    private let lock = NSLock()
    private var usbDevices = Set<Int>()
    private var connected = false

    func start() {
        Thread { [self] in watchLoop() }.start()
        Thread { [self] in connectLoop() }.start()
    }

    private func watchLoop() {
        while true {
            if let fd = UsbMux.openSocket() {
                if UsbMux.send(fd, ["MessageType": "Listen"]) {
                    while let message = UsbMux.receive(fd) {
                        handle(message)
                    }
                }
                close(fd)
            }
            lock.withLock { usbDevices.removeAll() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let type = message["MessageType"] as? String else { return }
        if type == "Attached",
           let id = message["DeviceID"] as? Int,
           let properties = message["Properties"] as? [String: Any],
           properties["ConnectionType"] as? String == "USB" {
            lock.withLock { _ = usbDevices.insert(id) }
        } else if type == "Detached", let id = message["DeviceID"] as? Int {
            lock.withLock { _ = usbDevices.remove(id) }
        }
    }

    /// For testing with Tools/fakephone: connect over plain TCP on this Mac instead of USB.
    private func connectDirect(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return fd }
        close(fd)
        return nil
    }

    private func connectLoop() {
        let directPort = ProcessInfo.processInfo.environment["I7_DIRECT_PORT"].flatMap { UInt16($0) }
        while true {
            let (busy, devices) = lock.withLock { (connected, usbDevices) }
            if !busy, let directPort {
                if let fd = connectDirect(port: directPort) { attach(fd) }
            } else if !busy {
                for device in devices {
                    if let fd = UsbMux.connect(deviceID: device, port: Wire.devicePort) {
                        attach(fd)
                        break
                    }
                }
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func attach(_ fd: Int32) {
        lock.withLock { connected = true }
        let connection = WireConnection(fd: fd)
        connection.onClose = { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.connected = false }
            self.onDisconnected?()
        }
        DispatchQueue.main.async { self.onConnected?(connection) }
    }
}
