import Foundation

/// Listens on the phone's loopback address. usbmuxd delivers the Mac's connection here over the cable.
final class PhoneServer {
    var onConnection: ((WireConnection) -> Void)?

    private var listenFD: Int32 = -1
    private let lock = NSLock()

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD < 0, let fd = Self.listenOnLoopback(port: Wire.devicePort) else { return }
        listenFD = fd

        Thread { [weak self] in self?.acceptLoop(fd) }.start()
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
        return fd
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD >= 0 else { return }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        listenFD = -1
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.main.async { [weak self] in
                self?.onConnection?(WireConnection(fd: client))
            }
        }
    }
}
