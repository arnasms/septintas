/// New phone builds travel over the USB cable on their own port, so sending one doesn't disturb the
/// connection to the Mac app. The sender writes a 4-byte big-endian length and the .ipa, and the
/// phone answers with one byte.
enum UpdatePush {
    static let port: UInt16 = 27_078
    static let maxSize = 64 * 1024 * 1024
    static let accepted: UInt8 = 1
    /// iOS found nothing to open TrollStore's install link, so its URL Scheme setting is off.
    static let urlSchemeOff: UInt8 = 0
}
