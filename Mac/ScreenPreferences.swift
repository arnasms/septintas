import Foundation

/// A fixed defaults domain keeps the choice stable for installed, rebuilt and directly launched apps.
enum ScreenSize: String, CaseIterable {
    case standard, moreSpace
    private static let preferences: UserDefaults = {
        let domain = "com.arnasmasalis.i7companion.mac"
        // The installed app already uses this domain. A named suite may fail to initialize.
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }()

    var points: (width: Int, height: Int) {
        switch self {
        case .standard: return (1024, 576)
        case .moreSpace: return (1334, 750)
        }
    }
    var title: String {
        switch self {
        case .standard: return "Default"
        case .moreSpace: return "More Space"
        }
    }
    static var saved: ScreenSize {
        get { load(from: preferences) }
        set { newValue.save(to: preferences) }
    }
    static func load(from preferences: UserDefaults) -> ScreenSize {
        let raw = preferences.string(forKey: "screenSize")
        let size = raw.flatMap(ScreenSize.init(rawValue:)) ?? .standard
        // Migrate the removed Larger Text choice and unknown legacy values.
        if raw != size.rawValue { size.save(to: preferences) }
        return size
    }
    func save(to preferences: UserDefaults) {
        preferences.set(rawValue, forKey: "screenSize")
        // Flush this explicit user choice before a quick quit/relaunch or rebuild can interrupt it.
        if !preferences.synchronize() { NSLog("i7: couldn't flush screen size preference") }
    }
}
