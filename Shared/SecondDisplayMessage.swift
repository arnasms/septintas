import Foundation

/// The second screen's private messages inside `MessageType.modeData`.
/// Mac -> phone is always a VideoPacket; phone -> Mac is this one request.
enum SecondDisplayMessage {
    static let keyframeRequest = Data([1])
}
