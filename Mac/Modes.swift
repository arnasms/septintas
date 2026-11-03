import AppKit
import CoreMedia
import ScreenCaptureKit

/// The Mac-side half of a phone mode (see PhoneMode). Each mode lives in the menu automatically
/// through `ModeID.allCases`, and gets a private channel to its phone-side view.
protocol MacMode: AnyObject {
    var id: ModeID { get }
    func start(send: @escaping (Data, _ droppable: Bool) -> Bool)
    func stop()
    /// Called on the connection's read thread.
    func receive(_ data: Data)
}

func makeMacMode(_ id: ModeID) -> MacMode {
    switch id {
    case .standby: return StandbyMacMode()
    case .secondDisplay: return SecondDisplayMacMode()
    case .dashboard: return DashboardMacMode()
    }
}

final class StandbyMacMode: MacMode {
    let id = ModeID.standby
    func start(send: @escaping (Data, Bool) -> Bool) {}
    func stop() {}
    func receive(_ data: Data) {}
}

/// Makes a real extra display for macOS, records it, and sends the picture to the phone.
final class SecondDisplayMacMode: NSObject, MacMode, SCStreamOutput, SCStreamDelegate {
    let id = ModeID.secondDisplay

    // iPhone 7 panel, in pixels. The video is always this size, whatever size macOS draws at.
    private let panelWidth = 1334
    private let panelHeight = 750

    private let queue = DispatchQueue(label: "second-display", qos: .userInteractive)
    private var display: I7VirtualDisplay?
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private var send: ((Data, Bool) -> Bool)?
    private var stopped = false
    private var captureGeneration = 0

    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime = Date.distantPast
    private var refreshesLeft = 0
    private var refreshTimer: DispatchSourceTimer?

    func start(send: @escaping (Data, Bool) -> Bool) {
        self.send = send
        guard makeDisplay() else {
            NSLog("i7: couldn't create the virtual display")
            return
        }

        guard let encoder = H264Encoder(width: panelWidth, height: panelHeight, fps: 60, bitrate: 12_000_000, lowLatency: true) else { return }
        encoder.onPacket = { [weak self, weak encoder] packet in
            guard self != nil, !send(packet.encoded(), !packet.isKeyframe) else { return }
            encoder?.forceNextKeyframe()
        }
        self.encoder = encoder
        startRefreshTimer()
        startCaptureLoop()
    }

    func stop() {
        stopped = true
        captureGeneration += 1
        send = nil
        refreshTimer?.cancel()
        refreshTimer = nil
        let oldStream = stream
        stream = nil
        Task { try? await oldStream?.stopCapture() }
        queue.sync { encoder = nil; lastFrame = nil }
        // Releasing this removes the display, so windows on it return to your other screens.
        display = nil
        queue.async { [self] in lastFrame = nil }
    }

    func receive(_ data: Data) {
        guard data == SecondDisplayMessage.keyframeRequest else { return }
        queue.async { [self] in
            encoder?.forceNextKeyframe()
            // The screen may be sitting still, with no new frame on the way, so resend the current one.
            if let lastFrame { encode(lastFrame) }
        }
    }

    func changeSize(_ size: ScreenSize) {
        ScreenSize.saved = size
        let oldStream = stream
        stream = nil
        Task { try? await oldStream?.stopCapture() }
        display = nil
        guard makeDisplay() else { return }
        startCaptureLoop()
    }

    private func makeDisplay() -> Bool {
        let size = ScreenSize.saved.points
        display = I7VirtualDisplay(
            name: "iPhone 7",
            maxPixelSize: CGSize(width: 2668, height: 1500),
            sizeInMillimeters: CGSize(width: 104, height: 58),
            modeWidth: UInt32(size.width),
            modeHeight: UInt32(size.height))
        return display != nil
    }

    private func startCaptureLoop() {
        captureGeneration += 1
        let generation = captureGeneration
        Task { await startCapture(attempt: 0, generation: generation) }
    }

    @MainActor
    private func startCapture(attempt: Int, generation: Int) async {
        guard !stopped, generation == captureGeneration, let displayID = display?.displayID else { return }
        if attempt == 0, !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        do {
            // A brand new display takes a moment to show up here.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !stopped, generation == captureGeneration else { return }
            guard let target = content.displays.first(where: { $0.displayID == displayID }) else {
                throw NSError(domain: "i7", code: 1)
            }
            let config = SCStreamConfiguration()
            config.width = panelWidth
            config.height = panelHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.queueDepth = 5
            config.showsCursor = true

            let filter = SCContentFilter(display: target, excludingWindows: [])
            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await newStream.startCapture()
            guard !stopped, generation == captureGeneration else {
                try? await newStream.stopCapture()
                return
            }
            stream = newStream
        } catch {
            NSLog("i7: capture attempt %d failed: %@", attempt, error.localizedDescription)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await startCapture(attempt: attempt + 1, generation: generation)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("i7: capture stopped: %@", error.localizedDescription)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, self.stream === stream else { return }
            self.stream = nil
            self.startCaptureLoop()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard encoder != nil, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        lastFrame = pixelBuffer
        lastFrameTime = Date()
        refreshesLeft = 3
        encode(pixelBuffer)
    }

    /// macOS sends nothing while the screen sits still, and the last frame of a burst of movement is
    /// usually the blurriest. Sending it again a few times lets the encoder sharpen the still picture.
    private func startRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self, let frame = self.lastFrame, self.refreshesLeft > 0,
                  Date().timeIntervalSince(self.lastFrameTime) > 0.2 else { return }
            self.refreshesLeft -= 1
            self.encode(frame)
        }
        timer.resume()
        refreshTimer = timer
    }

    private func encode(_ pixelBuffer: CVPixelBuffer) {
        let nanos = Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000_000)
        encoder?.encode(pixelBuffer, ptsNanos: nanos)
    }
}
