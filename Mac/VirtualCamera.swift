import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import VideoToolbox

/// Feeds frames into the "OBS Virtual Camera" that's already installed on this Mac.
/// That extension accepts frames from any app and passes them on untouched, and OBS itself doesn't
/// need to be open. Writing our own camera extension would need a paid Apple developer account.
final class VirtualCamera {
    private let deviceName = "OBS Virtual Camera"
    private var device: CMIOObjectID = 0
    private var sinkStream: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var format: CMVideoFormatDescription?
    private let lock = NSLock()
    private var watchedDevice: CMIOObjectID = 0

    var isAvailable: Bool { findDevice() != nil }

    /// True when anything has the camera open, including us. So it only means "an app wants the
    /// camera" while our own feed is stopped.
    var isInUse: Bool {
        guard let device = findDevice() else { return false }
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(device, &address, 0, nil, 4, &used, &value)
        return value != 0
    }

    /// Reports changes to `isInUse` on the main queue the moment macOS sees them. Safe to call
    /// repeatedly, since the camera may not exist yet the first time.
    func watchUsage(_ onChange: @escaping () -> Void) {
        guard let device = findDevice(), device != watchedDevice else { return }
        var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        let status = CMIOObjectAddPropertyListenerBlock(device, &address, .main) { _, _ in onChange() }
        if status == noErr { watchedDevice = device }
    }

    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if queue != nil { return true }
        guard let device = findDevice() else { return false }
        let streams = Self.objects(device, kCMIODevicePropertyStreams)
        // The extension publishes the output apps read first, then the input we write to.
        guard streams.count >= 2 else { return false }
        let sink = streams[1]

        var unmanaged: Unmanaged<CMSimpleQueue>?
        let callback: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }
        guard CMIOStreamCopyBufferQueue(sink, callback, nil, &unmanaged) == noErr, let unmanaged else { return false }
        guard CMIODeviceStartStream(device, sink) == noErr else {
            unmanaged.release()
            return false
        }
        self.device = device
        sinkStream = sink
        queue = unmanaged.takeRetainedValue()
        format = nil
        return true
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard queue != nil else { return }
        CMIODeviceStopStream(device, sinkStream)
        queue = nil
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let queue else { return }

        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: pixelBuffer) {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        }
        guard let format else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }

        // The queue takes ownership of one reference; if it's full, this frame is simply skipped.
        let element = Unmanaged.passRetained(sample)
        if CMSimpleQueueEnqueue(queue, element: element.toOpaque()) != noErr {
            element.release()
        }
    }

    private func findDevice() -> CMIOObjectID? {
        Self.objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
            .first { Self.name(of: $0) == deviceName }
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objects(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &out) == noErr else { return [] }
        return out
    }

    private static func name(of object: CMIOObjectID) -> String {
        var address = address(kCMIOObjectPropertyName)
        var used: UInt32 = 0
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, $0)
        }
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
}

/// Turns the phone's H.264 back into frames the virtual camera can use.
final class CameraDecoder {
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called when the picture can't continue until the phone sends a fresh keyframe.
    var onNeedsKeyframe: (() -> Void)?

    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private var lastParameterSets: [Data] = []

    /// Called only from the connection's read thread.
    func decode(_ packet: VideoPacket) {
        if packet.isKeyframe, packet.parameterSets != lastParameterSets {
            lastParameterSets = packet.parameterSets
            rebuild(packet)
        }
        guard let session, let format, let sample = packet.makeSampleBuffer(format: format) else {
            onNeedsKeyframe?()
            return
        }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                self?.onNeedsKeyframe?()
                return
            }
            self?.onFrame?(imageBuffer)
        }
        if status != noErr { onNeedsKeyframe?() }
    }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        lastParameterSets = []
    }

    private func rebuild(_ packet: VideoPacket) {
        reset()
        lastParameterSets = packet.parameterSets
        guard let newFormat = packet.makeFormatDescription() else { return }
        // IOSurface-backed BGRA: the format the OBS camera advertises, and the only kind of buffer
        // that can cross into its separate process without copying.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var created: VTDecompressionSession?
        if VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: newFormat, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created) == noErr {
            session = created
            format = newFormat
        }
    }
}
