import Foundation

// MARK: Limits and cost

/// Asks CodexBar's command-line tool, so the CodexBar app itself doesn't have to be running.
/// The tool ships inside the app, so the app does have to stay installed.
final class LimitsSource {
    var onUpdate: (([ProviderLimits], UsageState) -> Void)?

    private let tool: String
    private let accounts: () -> [DashboardAccount]
    private let defaults: UserDefaults

    /// The defaults are the real ones; limitscheck passes a fake tool, fixed accounts and scratch storage.
    init(tool: String = "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
         accounts: @escaping () -> [DashboardAccount] = { DashboardAccounts.selected() },
         defaults: UserDefaults = .standard) {
        self.tool = tool
        self.accounts = accounts
        self.defaults = defaults
        last = Self.loadSaved(from: defaults)
    }
    private let queue = DispatchQueue(label: "dashboard.limits")
    private var running = false
    /// Last good numbers, keyed by `DashboardAccount.id` so switching accounts back and forth keeps them.
    /// Saved to disk so a restart or a refused request doesn't blank a card; kept until their limits reset.
    private var last: [String: ProviderLimits] = [:]
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
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            // CodexBar was removed: forget saved numbers so a reinstall starts clean, and tell the phone why.
            if !last.isEmpty {
                last.removeAll()
                save()
            }
            onUpdate?([], .sourceMissing)
            interval = normalInterval
            queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.refresh(round) }
            return
        }
        var allFine = true
        let accounts = self.accounts()
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
        let state: UsageState = values.isEmpty || values.allSatisfy({ $0.unavailable == true }) ? .unavailable : .available
        onUpdate?(values, state)
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in self?.refresh(round) }
    }

    private static func loadSaved(from defaults: UserDefaults) -> [String: ProviderLimits] {
        guard let data = defaults.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode([String: ProviderLimits].self, from: data) else { return [:] }
        return saved.filter { !$0.value.allLimitsReset() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(last) else { return }
        defaults.set(data, forKey: Self.savedKey)
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
