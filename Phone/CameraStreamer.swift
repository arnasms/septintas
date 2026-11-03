import AVFoundation
import UIKit

/// Capture and encoder mutations are serialized, including camera replacement.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State: Equatable {
        case stopped, starting, live, failed(String)
    }
    var onPacket: ((VideoPacket) -> Bool)?
    var onState: ((State) -> Void)?
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera", qos: .userInteractive)
    private var input: AVCaptureDeviceInput?
    private var encoder: H264Encoder?
    private var position: AVCaptureDevice.Position = .front
    private var orientation: UIInterfaceOrientation = .landscapeRight
    private var requested = false
    private var generation = 0
    private var state: State = .stopped
    private var lastPacket = Date.distantPast
    private var watchdog: DispatchSourceTimer?

    override init() {
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(captureFailed), name: name, object: session)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self); watchdog?.cancel() }

    @objc private func captureFailed() {
        queue.async { [self] in
            guard requested else { return }
            halt()
            publish(.failed("Camera interrupted. Turn webcam off and on to retry."))
        }
    }

    private func publish(_ value: State) {
        guard state != value else { return }
        state = value
        DispatchQueue.main.async { [weak self] in self?.onState?(value) }
    }

    func start(orientation: UIInterfaceOrientation) {
        queue.async { [self] in
            self.orientation = orientation
            guard !requested else { return }
            requested = true
            restart()
        }
    }

    func selectCamera(back: Bool) {
        queue.async { [self] in
            let next: AVCaptureDevice.Position = back ? .back : .front
            guard next != position else { return }
            position = next
            if requested { restart() }
        }
    }

    func stop() {
        queue.async { [self] in requested = false; halt(); publish(.stopped) }
    }

    private func halt() {
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        encoder = nil
        if session.isRunning { session.stopRunning() }
    }

    private func restart() {
        halt()
        publish(.starting)
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            publish(.failed("Allow camera access in Settings, then turn webcam on again.")); return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let replacement = try? AVCaptureDeviceInput(device: device) else {
            publish(.failed("Selected camera is unavailable.")); return
        }
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        let previous = input
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(replacement) else {
            if let previous, session.canAddInput(previous) { session.addInput(previous) }
            session.commitConfiguration()
            publish(.failed("Could not switch camera.")); return
        }
        session.addInput(replacement)
        input = replacement
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                publish(.failed("Camera output is unavailable.")); return
            }
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
        }
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            device.unlockForConfiguration()
        }
        applyOrientation()
        guard let encoder = H264Encoder(width: 1920, height: 1080, fps: 30, bitrate: 8_000_000, lowLatency: false) else {
            publish(.failed("Could not start video encoder.")); return
        }
        self.encoder = encoder
        let current = generation
        encoder.onPacket = { [weak self] packet in
            guard let self else { return }
            self.queue.async {
                guard self.requested, self.generation == current else { return }
                if self.onPacket?(packet) == true {
                    self.lastPacket = Date()
                    self.publish(.live)
                } else {
                    self.publish(.starting)
                    self.encoder?.forceNextKeyframe()
                }
            }
        }
        encoder.forceNextKeyframe()
        lastPacket = Date()
        session.startRunning()
        guard session.isRunning else { halt(); publish(.failed("Camera did not start.")); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastPacket) > 3 else { return }
            self.halt()
            self.publish(.failed("Video stopped. Turn webcam off and on to retry."))
        }
        watchdog = timer
        timer.resume()
    }

    func forceKeyframe() { queue.async { [self] in encoder?.forceNextKeyframe() } }
    func setOrientation(_ orientation: UIInterfaceOrientation) {
        queue.async { [self] in
            guard self.orientation != orientation else { return }
            self.orientation = orientation
            if requested { restart() }
        }
    }
    private func applyOrientation() {
        guard let connection = output.connection(with: .video), connection.isVideoOrientationSupported else { return }
        connection.videoOrientation = orientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder?.encode(pixelBuffer, ptsNanos: Int64(pts.seconds * 1_000_000_000))
    }
}
