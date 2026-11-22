import Foundation

/// Reports which cameras have an app watching them, from the line Control Center logs whenever that
/// changes: the same information behind the camera indicator in the menu bar.
///
/// macOS's camera APIs count septintas feeding the OBS camera as using it, so they can't say when the
/// last real app lets go. Control Center's line only lists apps receiving frames. It is a log line, not
/// an API, so a macOS update can change it; then nothing is reported and the webcam stays on until it's
/// turned off from the menu, as before. Reading the live log needs an admin account.
final class CameraViewers {
    /// Main queue. The unique IDs of the cameras that now have at least one app watching.
    var onChange: ((Set<String>) -> Void)?

    static let marker = "Frame publisher cameras changed to "

    private let queue = DispatchQueue(label: "camera.viewers")
    private var process: Process?
    private var buffer = Data()
    private var running = false
    private var quickExits = 0

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            quickExits = 0
            launch()
        }
    }

    func stop() {
        queue.sync {
            running = false
            process?.terminate()
            process = nil
        }
    }

    /// The camera unique IDs in one of Control Center's lines, or nil for any other line.
    /// Looks like: `Frame publisher cameras changed to [com.apple.PhotoBooth: ["7626645E-…"]]`, or `[:]`.
    static func cameras(inMessage message: String) -> Set<String>? {
        guard let range = message.range(of: marker) else { return nil }
        let list = message[range.upperBound...]
        guard list.hasPrefix("[") else { return nil }
        var ids = Set<String>()
        var rest = list[...]
        while let open = rest.firstIndex(of: "\"") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "\"") else { break }
            ids.insert(String(rest[after..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return ids
    }

    private func launch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        // The timeout ends a copy left behind if this app is killed; a normal timeout just restarts it.
        task.arguments = ["stream", "--style", "ndjson", "--timeout", "1h", "--predicate",
                          "process == \"ControlCenter\" AND eventMessage BEGINSWITH \"\(Self.marker)\""]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.received(data) }
        }
        let started = Date()
        task.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            self?.queue.async { self?.ended(after: Date().timeIntervalSince(started)) }
        }
        buffer.removeAll()
        do {
            try task.run()
            process = task
        } catch {
            NSLog("i7: couldn't watch which apps use the camera: %@", error.localizedDescription)
            running = false
        }
    }

    private func ended(after seconds: TimeInterval) {
        process = nil
        guard running else { return }
        // Exiting straight away means the log isn't readable here, usually a non-admin account.
        quickExits = seconds < 5 ? quickExits + 1 : 0
        if quickExits >= 3 {
            NSLog("i7: can't read Control Center's camera log, so the webcam won't turn itself off")
            running = false
            return
        }
        queue.asyncAfter(deadline: .now() + (quickExits > 0 ? 10 : 0)) { [self] in
            if running, process == nil { launch() }
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<end)
            buffer.removeSubrange(buffer.startIndex...end)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let message = event["eventMessage"] as? String,
                  let cameras = Self.cameras(inMessage: message) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onChange?(cameras) }
        }
    }
}
