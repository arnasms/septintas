import Foundation

/// One framed, two-way connection over a connected socket: [type: 1 byte][length: 4 bytes, big endian][payload].
final class WireConnection {
    var onMessage: ((MessageType, Data) -> Void)?
    var onClose: (() -> Void)?

    private let fd: Int32
    private let sendQueue = DispatchQueue(label: "wire.send", qos: .userInteractive)
    private let lock = NSLock()
    private var pending = 0
    private var closed = false

    /// Above this many queued messages, droppable video is skipped instead of building up delay.
    private let maxPendingForDroppable = 4

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let thread = Thread { [self] in readLoop() }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Returns false when a droppable message was skipped; the caller should then force a keyframe.
    @discardableResult
    func send(_ type: MessageType, _ payload: Data = Data(), droppable: Bool = false) -> Bool {
        lock.lock()
        if closed || (droppable && pending >= maxPendingForDroppable) {
            lock.unlock()
            return false
        }
        pending += 1
        lock.unlock()

        sendQueue.async { [self] in
            var header = Data(count: Wire.headerSize)
            header[0] = type.rawValue
            let length = UInt32(payload.count)
            header[1] = UInt8(length >> 24 & 0xff)
            header[2] = UInt8(length >> 16 & 0xff)
            header[3] = UInt8(length >> 8 & 0xff)
            header[4] = UInt8(length & 0xff)

            let isClosed = lock.withLock { closed }
            if !isClosed {
                if !writeAll(header) || !writeAll(payload) { close() }
            }
            lock.withLock { pending -= 1 }
        }
        return true
    }

    func close() {
        lock.withLock {
            if !closed {
                closed = true
                shutdown(fd, SHUT_RDWR)
            }
        }
    }

    private func readLoop() {
        var header = [UInt8](repeating: 0, count: Wire.headerSize)
        while readAll(&header, count: Wire.headerSize) {
            let length = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
            if length > Wire.maxPayload { break }
            var payload = Data(count: length)
            let ok = length == 0 || payload.withUnsafeMutableBytes { raw in
                readRaw(raw.baseAddress!, count: length)
            }
            if !ok { break }
            if let type = MessageType(rawValue: header[0]) {
                onMessage?(type, payload)
            }
        }
        close()
        // Close on the send queue so a queued write can never land on a reused descriptor.
        sendQueue.async { [self] in
            Darwin.close(fd)
            DispatchQueue.main.async { self.onClose?() }
        }
    }

    private func readAll(_ buffer: inout [UInt8], count: Int) -> Bool {
        buffer.withUnsafeMutableBytes { readRaw($0.baseAddress!, count: count) }
    }

    private func readRaw(_ base: UnsafeMutableRawPointer, count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = read(fd, base + done, count - done)
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

    private func writeAll(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        return data.withUnsafeBytes { raw -> Bool in
            let base = raw.baseAddress!
            var done = 0
            while done < raw.count {
                let n = write(fd, base + done, raw.count - done)
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
}
