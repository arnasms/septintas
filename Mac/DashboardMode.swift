import EventKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Gathers everything the dashboard shows and sends it to the phone. Runs only while the mode is active.
final class DashboardMacMode: MacMode {
    let id = ModeID.dashboard

    private var send: ((Data, Bool) -> Bool)?
    private let limits = LimitsSource()
    private let nowPlaying = NowPlayingSource()
    private let calendar = CalendarSource()
    private let encoder = JSONEncoder()
    private let sendLock = NSLock()

    func start(send: @escaping (Data, Bool) -> Bool) {
        self.send = send
        limits.onUpdate = { [weak self] value in self?.deliver(DashboardUpdate(limits: value)) }
        nowPlaying.onUpdate = { [weak self] track, art in self?.deliver(DashboardUpdate(track: track, art: art)) }
        calendar.onUpdate = { [weak self] value in self?.deliver(DashboardUpdate(calendar: value)) }
        calendar.start()
        nowPlaying.start()
        limits.start()
    }

    func stop() {
        limits.stop()
        nowPlaying.stop()
        calendar.stop()
        send = nil
    }

    func receive(_ data: Data) {}

    private func deliver(_ update: DashboardUpdate) {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard let data = try? encoder.encode(update) else { return }
        _ = send?(data, false)
    }
}

// MARK: Limits and cost

/// Asks CodexBar's command-line tool, so the CodexBar app itself doesn't have to be running.
/// The tool ships inside the app, so the app does have to stay installed.
final class LimitsSource {
    var onUpdate: (([ProviderLimits]) -> Void)?

    private let tool = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI"
    private let queue = DispatchQueue(label: "dashboard.limits")
    private var running = false
    private var last: [ProviderLimits.Provider: ProviderLimits] = [:]
    private var lastSuccess: [ProviderLimits.Provider: Date] = [:]

    private let normalInterval: TimeInterval = 60
    private let longestInterval: TimeInterval = 600
    private let outOfDateAfter: TimeInterval = 300
    private var interval: TimeInterval = 60

    func start() {
        queue.async { [self] in
            running = true
            interval = normalInterval
            refresh()
        }
    }

    func stop() {
        queue.async { [self] in running = false }
    }

    private func refresh() {
        guard running else { return }
        var allFine = true
        for provider in [ProviderLimits.Provider.claude, .codex] {
            if let fresh = fetch(provider) {
                last[provider] = fresh
                lastSuccess[provider] = Date()
            } else {
                allFine = false
                NSLog("i7: couldn't refresh %@ limits", provider.rawValue)
                if let seen = lastSuccess[provider], Date().timeIntervalSince(seen) > outOfDateAfter {
                    last[provider]?.outOfDate = true
                }
            }
        }
        let values = [ProviderLimits.Provider.claude, .codex].compactMap { last[$0] }
        if !values.isEmpty { onUpdate?(values) }

        // If a request gets refused, wait longer each time rather than keep knocking every minute.
        interval = allFine ? normalInterval : min(interval * 2, longestInterval)
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.refresh() }
    }

    private func fetch(_ provider: ProviderLimits.Provider) -> ProviderLimits? {
        guard let usageData = run(["usage", "--provider", provider.rawValue, "--format", "json"]),
              let usage = Self.firstObject(usageData)?["usage"] as? [String: Any],
              let session = usage["primary"] as? [String: Any],
              let week = usage["secondary"] as? [String: Any] else { return nil }

        var today = 0.0
        var month = 0.0
        // 31 days always reaches the 1st of the current month.
        if let costData = run(["cost", "--provider", provider.rawValue, "--format", "json", "--days", "31"]),
           let daily = Self.firstObject(costData)?["daily"] as? [[String: Any]] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let todayKey = formatter.string(from: Date())
            let monthKey = String(todayKey.prefix(7))
            for day in daily {
                guard let date = day["date"] as? String, let cost = day["totalCost"] as? Double else { continue }
                if date == todayKey { today += cost }
                if date.hasPrefix(monthKey) { month += cost }
            }
        } else if let previous = last[provider] {
            today = previous.costToday
            month = previous.costMonth
        }

        return ProviderLimits(
            provider: provider,
            sessionPercent: Self.percent(session),
            sessionResets: Self.date(session["resetsAt"]),
            weekPercent: Self.percent(week),
            weekResets: Self.date(week["resetsAt"]),
            costToday: today,
            costMonth: month,
            outOfDate: false)
    }

    private func run(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func firstObject(_ data: Data) -> [String: Any]? {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        if let list = parsed as? [[String: Any]] { return list.first }
        return parsed as? [String: Any]
    }

    private static func percent(_ window: [String: Any]) -> Int {
        if let value = window["usedPercent"] as? Double { return Int(value.rounded()) }
        return window["usedPercent"] as? Int ?? 0
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}

// MARK: Now Playing

final class NowPlayingSource {
    var onUpdate: ((TrackInfo, Data?) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var lastSent: TrackInfo?
    private var lastSentAt = Date.distantPast
    private let resendEvery: TimeInterval = 5

    func start() {
        guard let library = Bundle.main.path(forResource: "now-playing", ofType: "dylib") else {
            NSLog("i7: now-playing helper is missing from the app")
            return
        }
        let script = "use DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die; "
            + "my $s = DynaLoader::dl_find_symbol($l, 'i7_now_playing') or die; "
            + "my $x = DynaLoader::dl_install_xsub('main::np', $s); &$x();"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = ["-e", script, library]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.received(handle.availableData)
        }
        do {
            try task.run()
            process = task
        } catch {
            NSLog("i7: couldn't start the now-playing helper: %@", error.localizedDescription)
        }
    }

    func stop() {
        if let output = process?.standardOutput as? Pipe {
            output.fileHandleForReading.readabilityHandler = nil
        }
        process?.terminate()
        process = nil
    }

    private func received(_ data: Data) {
        if data.isEmpty { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<end)
            buffer.removeSubrange(buffer.startIndex...end)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let info = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let title = info["title"] as? String ?? ""
        let track = TrackInfo(
            title: title,
            artist: info["artist"] as? String ?? "",
            duration: info["duration"] as? Double ?? 0,
            elapsed: info["elapsed"] as? Double ?? 0,
            isPlaying: (info["rate"] as? Double ?? 0) > 0,
            hasTrack: !title.isEmpty)

        var art: Data?
        if let encoded = info["art"] as? String, let full = Data(base64Encoded: encoded) {
            art = Self.thumbnail(full)
        }

        let changed = lastSent.map {
            $0.title != track.title || $0.artist != track.artist || $0.isPlaying != track.isPlaying || abs($0.duration - track.duration) > 0.5
        } ?? true
        guard changed || art != nil || Date().timeIntervalSince(lastSentAt) >= resendEvery else { return }
        lastSent = track
        lastSentAt = Date()
        onUpdate?(track, art)
    }

    /// The art is about 80pt square, so 180 pixels covers it on the phone. It usually arrives far larger.
    private static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 180,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return data }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { return data }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? result as Data : data
    }
}

// MARK: Calendar

final class CalendarSource {
    var onUpdate: ((CalendarStatus) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.onUpdate?(CalendarStatus(accessDenied: true))
                    return
                }
                self.refresh()
                self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
                self.observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: self.store, queue: .main) { [weak self] _ in
                    self?.refresh()
                }
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            timer?.invalidate()
            timer = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    private func refresh() {
        let now = Date()
        let until = now.addingTimeInterval(14 * 24 * 3600)
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-24 * 3600), end: until, calendars: nil))
        // All-day entries like birthdays aren't something to be on time for, and declined ones aren't happening.
        let upcoming = events
            .filter { !$0.isAllDay && $0.status != .canceled && $0.endDate > now && !Self.declined($0) }
            .sorted { $0.startDate < $1.startDate }
        guard !upcoming.isEmpty else {
            onUpdate?(CalendarStatus(accessDenied: false))
            return
        }
        // Include subsequent days so a quiet day does not leave the phone calendar half empty.
        let rest = upcoming.dropFirst(8)
        var moreColors: [CalendarColor] = []
        for event in rest {
            if let color = Self.color(of: event), !moreColors.contains(color) { moreColors.append(color) }
        }
        let days = Dictionary(grouping: upcoming) { Calendar.current.startOfDay(for: $0.startDate) }
            .map { day, events in
                CalendarDaySummary(date: day, count: events.count,
                                   colors: events.compactMap { Self.color(of: $0) }.reduce(into: []) { colors, color in
                                       if !colors.contains(color) { colors.append(color) }
                                   }, eventColors: events.map { Self.color(of: $0) })
            }.sorted { $0.date < $1.date }
        onUpdate?(CalendarStatus(
            events: upcoming.prefix(8).map {
                CalendarEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, color: Self.color(of: $0))
            },
            moreCount: rest.count,
            moreColors: moreColors,
            accessDenied: false,
            days: days))
    }

    private static func color(of event: EKEvent) -> CalendarColor? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let color = event.calendar?.cgColor?.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = color.components, parts.count >= 3 else { return nil }
        return CalendarColor(red: Double(parts[0]), green: Double(parts[1]), blue: Double(parts[2]))
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }
}
