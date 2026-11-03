import EventKit

/// Pure policy: inspecting setup never requests access or opens Settings.
enum CalendarSetup: Equatable {
    case request, upgrade, settings, restricted, ready

    init(authorization: EKAuthorizationStatus) {
        switch authorization {
        case .notDetermined: self = .request
        case .writeOnly: self = .upgrade
        case .denied: self = .settings
        case .restricted: self = .restricted
        case .fullAccess: self = .ready
        @unknown default: self = .settings
        }
    }

    var menuTitle: String? {
        switch self {
        case .request: return "Allow Calendar Full Access…"
        case .upgrade: return "Calendar needs Full Access…"
        case .settings: return "Calendar Access Denied — Setup…"
        case .restricted: return "Calendar Access Restricted — Help…"
        case .ready: return nil
        }
    }
}
