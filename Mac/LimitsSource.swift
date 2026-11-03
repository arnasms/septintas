import Foundation

/// Asks CodexBar's command-line tool, so the CodexBar app itself doesn't have to be running.
/// The tool ships inside the app, so the app does have to stay installed.
final class LimitsSource {
    var onUpdate: (([ProviderLimits], UsageState) -> Void)?

    private let tool: String

    init(tool: String = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI") {
        self.tool = tool
    }
    private let queue = DispatchQueue(label: "dashboard.limits")
    private var running = false
    private var generation = 0
    private var last: [ProviderLimits.Provider: ProviderLimits] = [:]
    private var lastSuccess: [ProviderLimits.Provider: Date] = [:]

    private let normalInterval: TimeInterval = 60
    private let longestInterval: TimeInterval = 600
    private let outOfDateAfter: TimeInterval = 300
    private var interval: TimeInterval = 60

    func start() {
        queue.async { [self] in
            generation += 1
            running = true
            interval = normalInterval
            refresh(generation: generation)
        }
    }

    func stop() {
        queue.async { [self] in running = false; generation += 1 }
    }

    private func refresh(generation token: Int) {
        guard running, token == generation else { return }
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            last.removeAll()
            lastSuccess.removeAll()
            onUpdate?([], .sourceMissing)
            interval = normalInterval
            scheduleRefresh(generation: token)
            return
        }
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
        onUpdate?(values, values.isEmpty ? .unavailable : .available)

        // If a request gets refused, wait longer each time rather than keep knocking every minute.
        interval = allFine ? normalInterval : min(interval * 2, longestInterval)
        scheduleRefresh(generation: token)
    }

    private func scheduleRefresh(generation token: Int) {
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.refresh(generation: token)
        }
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

