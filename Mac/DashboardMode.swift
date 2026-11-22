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
    /// Last good numbers, keyed by `DashboardAccount.id` so switching accounts back and forth keeps them.
    /// Saved to disk so a restart or a refused request doesn't blank a card; kept until their limits reset.
    private var last: [String: ProviderLimits] = LimitsSource.loadSaved()
    private static let savedKey = "dashboardLastLimits"
    /// Bumped when the picked accounts change, so the old refresh loop stops and a new one starts now.
    private var generation = 0
    private var observer: NSObjectProtocol?

    private let normalInterval: TimeInterval = 60
    private let longestInterval: TimeInterval = 600
    private let outOfDateAfter: TimeInterval = 300
    private var interval: TimeInterval = 60

    func start() {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: DashboardAccounts.changed, object: nil, queue: nil) { [weak self] _ in
                self?.restart()
            }
        }
        restart()
    }

    func stop() {
        queue.async { [self] in
            running = false
            generation += 1
        }
    }

    private func restart() {
        queue.async { [self] in
            running = true
            interval = normalInterval
            generation += 1
            refresh(generation)
        }
    }

    private func refresh(_ round: Int) {
        guard running, round == generation else { return }
        var allFine = true
        let accounts = DashboardAccounts.selected()
        let sameProvider = accounts.count > 1 && Set(accounts.map(\.provider)).count == 1
        // Cost can't be split by account, so only the last card of each provider carries it.
        var costSlot: [ProviderLimits.Provider: Int] = [:]
        for (slot, account) in accounts.enumerated() { costSlot[account.provider] = slot }
        var refreshed = Set<String>()
        for (slot, account) in accounts.enumerated() {
            if var fresh = fetch(account, includeCost: costSlot[account.provider] == slot) {
                fresh.updatedAt = Date()
                last[account.id] = fresh
                refreshed.insert(account.id)
            } else {
                allFine = false
                NSLog("i7: couldn't refresh %@ limits", account.id)
            }
        }
        // A newer selection may have started while this one was fetching; let it send instead.
        guard round == generation else { return }
        if !refreshed.isEmpty { save() }

        // If a request gets refused, wait longer each time rather than keep knocking every minute.
        interval = allFine ? normalInterval : min(interval * 2, longestInterval)
        let now = Date()
        let next = now.addingTimeInterval(interval)
        var values: [ProviderLimits] = []
        for (slot, account) in accounts.enumerated() {
            let sharesCost = costSlot[account.provider] != slot
            if last[account.id]?.allLimitsReset(at: now) == true { last[account.id] = nil }
            // Every picked account always gets its card, so the phone never keeps showing an account
            // that was picked before this one.
            var value = last[account.id] ?? placeholder(account, includeCost: !sharesCost)
            let stale = !refreshed.contains(account.id)
            value.stale = stale
            value.nextUpdateAt = stale ? next : nil
            // Phones from before `stale` only understand this flag.
            value.outOfDate = stale && now.timeIntervalSince(value.updatedAt ?? .distantPast) > outOfDateAfter
            value.slot = slot
            value.accountName = sameProvider ? account.shortName : nil
            value.costShared = sharesCost
            values.append(value)
        }
        if !values.isEmpty { onUpdate?(values) }
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.refresh(round) }
    }

    private static func loadSaved() -> [String: ProviderLimits] {
        guard let data = UserDefaults.standard.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode([String: ProviderLimits].self, from: data) else { return [:] }
        return saved.filter { !$0.value.allLimitsReset() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(last) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedKey)
    }

    /// A card for an account whose usage has never loaded. Cost comes from local logs, so it can still show.
    private func placeholder(_ source: DashboardAccount, includeCost: Bool) -> ProviderLimits {
        let cost = includeCost ? self.cost(source.provider) : nil
        var value = ProviderLimits(
            provider: source.provider, sessionPercent: 0, sessionResets: nil, weekPercent: 0, weekResets: nil,
            costToday: cost?.today ?? 0, costMonth: cost?.month ?? 0, outOfDate: false)
        value.unavailable = true
        return value
    }

    /// Today's and this month's cost for a provider, from its local logs.
    private func cost(_ provider: ProviderLimits.Provider) -> (today: Double, month: Double)? {
        // 31 days always reaches the 1st of the current month.
        guard let costData = run(["cost", "--provider", provider.rawValue, "--format", "json", "--days", "31"]),
              let daily = Self.firstObject(costData)?["daily"] as? [[String: Any]] else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let todayKey = formatter.string(from: Date())
        let monthKey = String(todayKey.prefix(7))
        var today = 0.0
        var month = 0.0
        for day in daily {
            guard let date = day["date"] as? String, let cost = day["totalCost"] as? Double else { continue }
            if date == todayKey { today += cost }
            if date.hasPrefix(monthKey) { month += cost }
        }
        return (today, month)
    }

    private func fetch(_ source: DashboardAccount, includeCost: Bool) -> ProviderLimits? {
        let provider = source.provider
        var usageArguments = ["usage", "--provider", provider.rawValue, "--format", "json"]
        if let account = source.account { usageArguments += ["--account", account] }
        guard let usageData = run(usageArguments),
              let usage = Self.firstObject(usageData)?["usage"] as? [String: Any] else { return nil }
        // Take whichever limits the plan has rather than insisting on a 5-hour and a weekly one.
        let windows = ["primary", "secondary"].compactMap { usage[$0] as? [String: Any] }.map(Self.window)
        guard !windows.isEmpty else { return nil }

        var today = 0.0
        var month = 0.0
        // Cost is read from local logs per provider, so a second account of the same provider
        // doesn't fetch it again: the provider's cost is shown on its other card.
        if !includeCost {
        } else if let cost = cost(provider) {
            today = cost.today
            month = cost.month
        } else if let previous = last[source.id] {
            today = previous.costToday
            month = previous.costMonth
        }

        var value = ProviderLimits(
            provider: provider,
            sessionPercent: windows[0].percent,
            sessionResets: windows[0].resets,
            weekPercent: windows.count > 1 ? windows[1].percent : 0,
            weekResets: windows.count > 1 ? windows[1].resets : nil,
            costToday: today,
            costMonth: month,
            outOfDate: false)
        value.windows = windows
        return value
    }

    private static func window(_ raw: [String: Any]) -> LimitWindow {
        let minutes = (raw["windowMinutes"] as? Int) ?? (raw["windowMinutes"] as? Double).map { Int($0) }
        return LimitWindow(title: title(minutes: minutes), percent: percent(raw), resets: date(raw["resetsAt"]), minutes: minutes)
    }

    static func title(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Limit" }
        switch minutes {
        case 10080: return "Week"
        case 40320...44640: return "Month"
        case ..<1440 where minutes % 60 == 0: return minutes == 60 ? "1 hour" : "\(minutes / 60) hours"
        case ..<1440: return "\(minutes) min"
        case _ where minutes % 1440 == 0: return minutes == 1440 ? "Day" : "\(minutes / 1440) days"
        default: return "\(minutes / 60) hours"
        }
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
