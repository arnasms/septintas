import Foundation

// Sends a new build to the app on the plugged-in iPhone, which passes it to TrollStore.
//
// Usage: pushphone <file.ipa>

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

guard CommandLine.arguments.count > 1, let build = FileManager.default.contents(atPath: CommandLine.arguments[1]) else {
    fail("Couldn't read the build file.")
}

// usbmuxd lists every attached phone right after Listen, then waits, so a short timeout ends the list.
var devices: [Int] = []
guard let watcher = UsbMux.openSocket(), UsbMux.send(watcher, ["MessageType": "Listen"]) else {
    fail("Couldn't reach the Mac's USB service.")
}
var timeout = timeval(tv_sec: 1, tv_usec: 0)
setsockopt(watcher, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
while let message = UsbMux.receive(watcher) {
    if message["MessageType"] as? String == "Attached",
       let id = message["DeviceID"] as? Int,
       (message["Properties"] as? [String: Any])?["ConnectionType"] as? String == "USB" {
        devices.append(id)
    }
}
close(watcher)
if devices.isEmpty { fail("No iPhone on USB.") }

// Only a phone running a build with the updater accepts, so a second iPhone being plugged in does no harm.
guard let fd = devices.lazy.compactMap({ UsbMux.connect(deviceID: $0, port: UpdatePush.port) }).first else {
    fail("The phone isn't accepting builds. The app needs to be open, and new enough to have the updater.")
}

var packet = Data()
withUnsafeBytes(of: UInt32(build.count).bigEndian) { packet.append(contentsOf: $0) }
packet.append(build)
let sent = packet.withUnsafeBytes { raw -> Bool in
    var done = 0
    while done < raw.count {
        let n = write(fd, raw.baseAddress! + done, raw.count - done)
        if n <= 0 { return false }
        done += n
    }
    return true
}
if !sent { fail("The connection dropped while sending.") }

var wait = timeval(tv_sec: 20, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
var answer: UInt8 = 255
if read(fd, &answer, 1) != 1 { fail("Sent, but the phone didn't answer.") }
switch answer {
case UpdatePush.accepted:
    print("Sent \(build.count) bytes. TrollStore is taking it from here.")
case UpdatePush.urlSchemeOff:
    fail("The phone has the build, but TrollStore refused the link. Turn on URL Scheme Enabled in TrollStore's Settings.")
default:
    fail("The phone gave an unexpected answer.")
}
