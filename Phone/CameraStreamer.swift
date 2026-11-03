import AVFoundation
import UIKit

/// Front camera -> H.264 -> Mac. Runs only while the Mac asks for it, since it's the part that heats the phone up.
final class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onPacket: ((VideoPacket) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera", qos: .userInteractive)
    private var configured = false
    private var encoder: H264Encoder?

    // The OBS camera advertises 1920x1080, so sending that avoids any scaling in the apps that read it.
    private let width = 1920
    private let height = 1080
    private let fps = 30
    private let bitrate = 8_000_000

    func start(orientation: UIInterfaceOrientation) {
        queue.async { [self] in
            if !configured { configure() }
            guard configured else { return }
            apply(orientation)
            encoder = H264Encoder(width: width, height: height, fps: fps, bitrate: bitrate, lowLatency: false)
            encoder?.onPacket = { [weak self] packet in self?.onPacket?(packet) }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            encoder = nil
        }
    }

    func forceKeyframe() {
        queue.async { [self] in encoder?.forceNextKeyframe() }
    }

    func setOrientation(_ orientation: UIInterfaceOrientation) {
        queue.async { [self] in apply(orientation) }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        session.commitConfiguration()

        if (try? device.lockForConfiguration()) != nil {
            let frame = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
            device.unlockForConfiguration()
        }
        configured = true
    }

    /// Keeps the picture upright for whichever way round the phone sits in landscape.
    private func apply(_ orientation: UIInterfaceOrientation) {
        guard let connection = output.connection(with: .video), connection.isVideoOrientationSupported else { return }
        connection.videoOrientation = orientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder?.encode(pixelBuffer, ptsNanos: Int64(pts.seconds * 1_000_000_000))
    }
}
