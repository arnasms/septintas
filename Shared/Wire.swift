import Foundation

enum Wire {
    /// Port the phone listens on. The Mac reaches it through usbmuxd, so it only ever travels over the cable.
    static let devicePort: UInt16 = 27_077
    static let protocolVersion: UInt8 = 1
    static let maxPayload = 16 * 1024 * 1024
    static let headerSize = 5
}

enum MessageType: UInt8 {
    case hello = 1
    /// Mac -> phone: one byte, a ModeID.
    case setMode = 2
    /// Mac -> phone: one byte, 0 or 1.
    case setCamera = 3
    /// Phone -> Mac: a VideoPacket from the camera.
    case cameraVideo = 4
    /// Mac -> phone: the camera decoder needs a fresh keyframe.
    case cameraKeyframeRequest = 5
    /// Either way: belongs to whichever mode is active. The transport never looks inside it.
    case modeData = 6
    /// Mac -> phone: exactly one byte, 0 allows Auto-Lock, 1 prevents it.
    case setSleepPrevention = 7
    /// Mac -> phone: exactly one byte, 0 front, 1 back.
    case setCameraPosition = 8
}

/// What the phone's screen is doing. The webcam runs independently of this.
/// To add a view: add a case here, then the compiler points at the two registries to fill in
/// (`makePhoneMode` in Phone/Modes.swift and `makeMacMode` in Mac/Modes.swift).
enum ModeID: UInt8, CaseIterable {
    /// Legacy wire value, retained for compatibility; no longer offered in the menu.
    case standby = 0
    case secondDisplay = 1
    case dashboard = 2

    static let selectableCases: [ModeID] = [.secondDisplay, .dashboard]

    var title: String {
        switch self {
        case .standby: return "Standby"
        case .secondDisplay: return "Second Screen"
        case .dashboard: return "Dashboard"
        }
    }
}
