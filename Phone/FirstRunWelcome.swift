import Foundation

/// Old builds had no launch marker. An update retains its older data container; a fresh install
/// creates one after the executable was built. If dates are unavailable, prefer skipping welcome.
enum FirstRunWelcome {
    static let seenKey = "firstRunWelcomeSeen"

    static func claim(defaults: UserDefaults = .standard) -> Bool {
        #if WELCOME_PREVIEW
        // Test IPA only: preview on existing installs without changing their saved state.
        return true
        #else
        let seen = defaults.bool(forKey: seenKey)
        // Claim on launch, rather than rotation: quitting during welcome must not repeat it.
        defaults.set(true, forKey: seenKey)
        let manager = FileManager.default
        let containerDate = (try? manager.attributesOfItem(atPath: NSHomeDirectory()))?[.creationDate] as? Date
        let buildDate = Bundle.main.executableURL.flatMap {
            (try? manager.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        return shouldWelcome(seen: seen, containerDate: containerDate, buildDate: buildDate)
        #endif
    }

    static func shouldWelcome(seen: Bool, containerDate: Date?, buildDate: Date?) -> Bool {
        guard !seen, let containerDate, let buildDate else { return false }
        return containerDate >= buildDate
    }
}
