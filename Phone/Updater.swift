import UIKit

/// Takes a new build from Tools/pushphone and hands it to TrollStore. TrollStore's only way to be
/// given a file without a person is a link it downloads from, so the app briefly serves the build
/// to itself on this phone's loopback address.
final class Updater {
    private let servePort: UInt16 = 27_079
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var served = Data()
    private var serving = false
    private let lock = NSLock()

    func start() {
        guard let fd = PhoneServer.listenOnLoopback(port: UpdatePush.port) else { return }
        Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                self?.receive(from: client)
            }
        }.start()
    }

    private func receive(from client: Int32) {
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard let header = Self.read(client, count: 4) else {
            close(client)
            return
        }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= UpdatePush.maxSize, let build = Self.read(client, count: length) else {
            close(client)
            return
        }
        serve(build)

        DispatchQueue.main.async { [self] in
            // TrollStore comes to the front now, and iOS would freeze this app before it finished downloading.
            backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                guard let self else { return }
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
            }
            var link = URLComponents()
            link.scheme = "apple-magnifier"
            link.host = "install"
            link.queryItems = [URLQueryItem(name: "url", value: "http://127.0.0.1:\(servePort)/i7.ipa")]
            UIApplication.shared.open(link.url!) { opened in
                var answer = opened ? UpdatePush.accepted : UpdatePush.urlSchemeOff
                _ = write(client, &answer, 1)
                close(client)
            }
        }
    }

    private func serve(_ build: Data) {
        lock.lock()
        served = build
        let alreadyServing = serving
        serving = true
        lock.unlock()
        guard !alreadyServing, let fd = PhoneServer.listenOnLoopback(port: servePort) else { return }
        Thread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                self?.answer(client)
            }
        }.start()
    }

    private func answer(_ client: Int32) {
        defer { close(client) }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var request = [UInt8](repeating: 0, count: 4096)
        _ = Darwin.read(client, &request, request.count)

        lock.lock()
        let build = served
        lock.unlock()
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(build.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(build)
        response.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let n = write(client, raw.baseAddress! + done, raw.count - done)
                if n <= 0 { return }
                done += n
            }
        }
    }

    private static func read(_ fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            var done = 0
            while done < count {
                let n = Darwin.read(fd, raw.baseAddress! + done, count - done)
                if n <= 0 { return false }
                done += n
            }
            return true
        }
        return complete ? data : nil
    }
}
