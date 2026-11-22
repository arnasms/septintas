import Foundation

/// Listens on the phone's loopback address. usbmuxd delivers the Mac's connection here over the cable.
final class PhoneServer {
    var onConnection: ((WireConnection) -> Void)?

    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var generation = 0
    private var stopped: DispatchSemaphore?

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD < 0, let fd = Self.listenOnLoopback(port: Wire.devicePort) else { return }
        listenFD = fd
        generation += 1
        let token = generation
        let done = DispatchSemaphore(value: 0)
        stopped = done
        Thread { [self] in
            acceptLoop(fd, generation: token)
            done.signal()
        }.start()
    }

    static func listenOnLoopback(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 2) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }

    func stop() {
        lock.lock()
        guard listenFD >= 0 else { lock.unlock(); return }
        shutdown(listenFD, SHUT_RDWR)
        generation += 1
        listenFD = -1
        let done = stopped
        stopped = nil
        lock.unlock()
        // Shutdown wakes accept; wait for its owner to release the port before a restart.
        done?.wait()
    }

    private func acceptLoop(_ fd: Int32, generation token: Int) {
        // Only this thread closes the descriptor; stop cannot race accept on a reused fd.
        defer { close(fd) }
        while lock.withLock({ generation == token }) {
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 100)
            if ready == 0 { continue }
            if ready < 0 { if errno == EINTR { continue }; return }
            guard lock.withLock({ generation == token }) else { return }
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EAGAIN || errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFL, 0)
            var on: Int32 = 1
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.main.async { [weak self] in
                let connection = WireConnection(fd: client)
                guard let self, self.lock.withLock({ self.generation == token }) else {
                    connection.close()
                    return
                }
                self.onConnection?(connection)
            }
        }
    }
}
