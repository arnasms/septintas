import CoreImage
import CoreVideo
import Foundation

// Stands in for the iPhone so the Mac's pipeline can be tested without one: it runs on the Mac,
// decodes the second screen's video, saves a frame as a PNG, and answers webcam requests with a
// moving test pattern.
//
// Usage: fakephone <seconds> <output.png>
// Pair it with the Mac app started with I7_DIRECT_PORT set to the phone's port.

let seconds = Double(CommandLine.arguments[1])!
let outputPath = CommandLine.arguments[2]

let fd = socket(AF_INET, SOCK_STREAM, 0)
var on: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = Wire.devicePort.bigEndian
address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
_ = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
listen(fd, 1)
print("listening on \(Wire.devicePort)")

let client = accept(fd, nil, nil)
print("mac connected")
let connection = WireConnection(fd: client)
let decoder = CameraDecoder()
var screenFrames = 0
var keyframes = 0
var bytes = 0
var savedPNG = false
let started = Date()
var firstFrameDelay: Double?

decoder.onFrame = { frame in
    screenFrames += 1
    if firstFrameDelay == nil { firstFrameDelay = Date().timeIntervalSince(started) }
    if !savedPNG, screenFrames > 20 {
        savedPNG = true
        let image = CIImage(cvPixelBuffer: frame)
        try? CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: outputPath), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        print("saved \(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame)) frame to \(outputPath)")
    }
}
decoder.onNeedsKeyframe = { connection.send(.modeData, SecondDisplayMessage.keyframeRequest) }

var cameraTimer: DispatchSourceTimer?
var cameraEncoder: H264Encoder?
var cameraPacketsSent = 0

func setCamera(_ on: Bool) {
    print("camera requested: \(on)")
    cameraTimer?.cancel()
    cameraTimer = nil
    cameraEncoder = nil
    guard on else { return }
    let encoder = H264Encoder(width: 1920, height: 1080, fps: 30, bitrate: 8_000_000, lowLatency: false)!
    encoder.onPacket = { packet in
        cameraPacketsSent += 1
        connection.send(.cameraVideo, packet.encoded(), droppable: !packet.isKeyframe)
    }
    cameraEncoder = encoder
    var pool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, nil, [
        kCVPixelBufferWidthKey: 1920, kCVPixelBufferHeightKey: 1080,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
    ] as CFDictionary, &pool)
    var frame = 0
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now(), repeating: 1.0 / 30)
    timer.setEventHandler {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &buffer)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bar = frame * 8 % 1920
        for y in 0..<1080 {
            let line = base + y * row
            for x in 0..<1920 {
                let p = line + x * 4
                let lit = abs(x - bar) < 40
                p[0] = lit ? 255 : 120
                p[1] = lit ? 255 : UInt8(y * 255 / 1080)
                p[2] = lit ? 255 : UInt8(x * 255 / 1920)
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        frame += 1
        cameraEncoder?.encode(buffer, ptsNanos: Int64(frame) * 33_333_333)
    }
    timer.resume()
    cameraTimer = timer
}

func printDashboard(_ payload: Data) {
    guard let update = try? JSONDecoder().decode(DashboardUpdate.self, from: payload) else {
        print("dashboard: couldn't decode")
        return
    }
    for limits in update.limits ?? [] {
        print("limits \(limits.provider.rawValue): 5h \(limits.sessionPercent)% resets \(limits.sessionResets.map(String.init(describing:)) ?? "-"), week \(limits.weekPercent)% resets \(limits.weekResets.map(String.init(describing:)) ?? "-"), $\(String(format: "%.2f", limits.costToday)) today, $\(String(format: "%.2f", limits.costMonth)) month, outOfDate \(limits.outOfDate)")
    }
    if let track = update.track {
        print("track: \(track.title) / \(track.artist), \(Int(track.elapsed))s of \(Int(track.duration))s, playing \(track.isPlaying)")
    }
    if let art = update.art {
        print("art: \(art.count) bytes")
    }
    if let calendar = update.calendar {
        print("calendar: \(calendar.events.count) shown, starts \(calendar.events.map { String(describing: $0.start) }), \(calendar.moreCount) more in \(calendar.moreColors.count) colours, denied \(calendar.accessDenied)")
    }
}

connection.onMessage = { type, payload in
    switch type {
    case .setMode:
        print("mode: \(payload.first.flatMap { ModeID(rawValue: $0) }?.title ?? "?")")
    case .setCamera:
        setCamera(payload.first == 1)
    case .modeData:
        bytes += payload.count
        if payload.first == UInt8(ascii: "{") {
            printDashboard(payload)
            return
        }
        guard let packet = VideoPacket(data: payload) else { return }
        if packet.isKeyframe { keyframes += 1 }
        decoder.decode(packet)
    default:
        break
    }
}
connection.onClose = {
    print("mac disconnected")
    exit(0)
}
connection.start()
connection.send(.hello, Data([Wire.protocolVersion]))
connection.send(.modeData, SecondDisplayMessage.keyframeRequest)

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    print("decoded frames: \(screenFrames), keyframes: \(keyframes), MB received: \(bytes / 1_000_000), first frame after: \(firstFrameDelay.map { String(format: "%.2fs", $0) } ?? "never"), camera packets sent: \(cameraPacketsSent)")
    exit(0)
}
dispatchMain()
