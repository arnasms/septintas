import AVFoundation
import UIKit

/// One thing the phone's screen can show. It gets its own full-screen view and a private channel to
/// its Mac-side half (see MacMode). The webcam, the connection and the always-on screen carry on
/// underneath no matter which mode is active.
protocol PhoneMode: AnyObject {
    var id: ModeID { get }
    var view: UIView { get }
    /// Call once there's something worth revealing. The waiting screen holds until then.
    var onReady: (() -> Void)? { get set }
    func start(send: @escaping (Data) -> Void)
    func stop()
    /// Called on the connection's read thread.
    func receive(_ data: Data)
}

func makePhoneMode(_ id: ModeID) -> PhoneMode {
    switch id {
    case .standby: return StandbyPhoneMode()
    case .secondDisplay: return SecondDisplayPhoneMode()
    case .dashboard: return DashboardPhoneMode()
    }
}

/// Nothing to show: black, apart from a small note saying the phone is doing its job.
final class StandbyPhoneMode: PhoneMode {
    let id = ModeID.standby
    let view = UIView()
    var onReady: (() -> Void)?

    init() {
        view.backgroundColor = .black
        let label = UILabel()
        label.text = "Connected"
        label.textColor = UIColor(white: 0.35, alpha: 1)
        label.font = .systemFont(ofSize: 15)
        label.textAlignment = .center
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }

    func start(send: @escaping (Data) -> Void) {
        onReady?()
        onReady = nil
    }
    func stop() {}
    func receive(_ data: Data) {}
}

final class SecondDisplayPhoneMode: PhoneMode {
    let id = ModeID.secondDisplay
    private let videoView = VideoLayerView()
    var view: UIView { videoView }
    var onReady: (() -> Void)?

    private let lock = NSLock()
    private var format: CMFormatDescription?
    private var lastParameterSets: [Data] = []
    private var send: ((Data) -> Void)?
    private var showedPicture = false

    func start(send: @escaping (Data) -> Void) {
        self.send = send
        videoView.videoLayer.videoGravity = .resizeAspect
        send(SecondDisplayMessage.keyframeRequest)
    }

    func stop() {
        send = nil
        videoView.videoLayer.flushAndRemoveImage()
    }

    func receive(_ data: Data) {
        guard let packet = VideoPacket(data: data) else { return }
        lock.lock()
        defer { lock.unlock() }

        if packet.isKeyframe, packet.parameterSets != lastParameterSets {
            format = packet.makeFormatDescription()
            lastParameterSets = packet.parameterSets
        }
        guard let format, let sample = packet.makeSampleBuffer(format: format) else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let layer = videoView.videoLayer
        if layer.status == .failed {
            // Usually the app coming back from the background. A keyframe gets the picture going again.
            layer.flush()
            send?(SecondDisplayMessage.keyframeRequest)
            if !packet.isKeyframe { return }
        }
        layer.enqueue(sample)
        if !showedPicture {
            showedPicture = true
            DispatchQueue.main.async { [self] in
                onReady?()
                onReady = nil
            }
        }
    }
}

private final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }
}
