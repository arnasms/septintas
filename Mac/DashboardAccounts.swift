import Foundation

/// One usage source the dashboard can show: a provider, optionally narrowed to one of the accounts
/// saved in CodexBar (its "token accounts"). `account` is CodexBar's label, passed to `--account`.
struct DashboardAccount: Hashable {
    var provider: ProviderLimits.Provider
    var account: String?

    var id: String { provider.rawValue + "|" + (account ?? "") }

    var providerName: String { provider == .claude ? "Claude" : "Codex" }

    /// Menu title: the CodexBar label when there is one, otherwise the provider.
    var menuTitle: String { account ?? providerName }

    /// Short account name shown after the provider name on the phone ("Claude main", "Claude 3").
    var shortName: String? {
        guard var name = account?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        if name.lowercased().hasPrefix(providerName.lowercased()) {
            name = String(name.dropFirst(providerName.count)).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? account : name
    }

    init(provider: ProviderLimits.Provider, account: String?) {
        self.provider = provider
        self.account = account
    }

    init?(id: String) {
        let parts = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let provider = ProviderLimits.Provider(rawValue: String(parts[0])) else { return nil }
        self.provider = provider
        self.account = parts[1].isEmpty ? nil : String(parts[1])
    }
}

/// Which two accounts the dashboard shows, picked from the menu bar.
enum DashboardAccounts {
    static let limit = 2
    static let changed = Notification.Name("DashboardAccountsChanged")

    private static let key = "dashboardAccounts"
    private static let preferences: UserDefaults = {
        let domain = "com.arnasmasalis.i7companion.mac"
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }()

    /// Every enabled Claude or Codex source in CodexBar's config, Claude first. A provider with
    /// saved accounts lists each account; one without lists its normal login.
    static func available() -> [DashboardAccount] {
        let providers = readConfigProviders()
        var result: [DashboardAccount] = []
        for provider in [ProviderLimits.Provider.claude, .codex] {
            let entry = providers.first { $0["id"] as? String == provider.rawValue }
            if let entry, entry["enabled"] as? Bool == false { continue }
            let labels = ((entry?["tokenAccounts"] as? [String: Any])?["accounts"] as? [[String: Any]] ?? [])
                .compactMap { ($0["label"] as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if labels.isEmpty {
                result.append(DashboardAccount(provider: provider, account: nil))
            } else {
                result += labels.map { DashboardAccount(provider: provider, account: $0) }
            }
        }
        return result
    }

    /// The picked accounts in menu order, still present in CodexBar. Falls back to the first Claude
    /// and first Codex source, which is what the dashboard always showed before.
    static func selected(from available: [DashboardAccount] = available()) -> [DashboardAccount] {
        let picked = Set((preferences.stringArray(forKey: key) ?? []).compactMap(DashboardAccount.init(id:)))
        let kept = available.filter { picked.contains($0) }
        if !kept.isEmpty { return Array(kept.prefix(limit)) }
        let defaults = [ProviderLimits.Provider.claude, .codex].compactMap { provider in
            available.first { $0.provider == provider }
        }
        return Array((defaults.isEmpty ? available : defaults).prefix(limit))
    }

    /// Ticks or unticks one account. Ticking a third replaces the one picked longest ago, and the
    /// last remaining account can't be unticked.
    static func toggle(_ account: DashboardAccount) {
        let available = available()
        let current = selected(from: available)
        let history = (preferences.stringArray(forKey: key) ?? []).compactMap(DashboardAccount.init(id:))
            .filter { current.contains($0) }
        var order = history + current.filter { !history.contains($0) }
        if order.contains(account) {
            guard order.count > 1 else { return }
            order.removeAll { $0 == account }
        } else {
            order.append(account)
            if order.count > limit { order.removeFirst(order.count - limit) }
        }
        preferences.set(order.map(\.id), forKey: key)
        preferences.synchronize()
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func readConfigProviders() -> [[String: Any]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [".config/codexbar/config.json", ".codexbar/config.json"].map { home.appendingPathComponent($0) }
        for url in paths {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return json["providers"] as? [[String: Any]] ?? []
        }
        return []
    }
}
