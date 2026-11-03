import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 tuned for delay rather than file size. Used by the Mac for the screen and the phone for the camera.
final class H264Encoder {
    var onPacket: ((VideoPacket) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var wantsKeyframe = true

    init?(width: Int, height: Int, fps: Int, bitrate: Int, lowLatency: Bool) {
        var created: VTCompressionSession?
        var status: OSStatus = -1
        if lowLatency {
            let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        if status != noErr {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let created else { return nil }
        session = created

        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 4 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    func forceNextKeyframe() {
        lock.withLock { wantsKeyframe = true }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsNanos: Int64) {
        guard let session else { return }
        let force = lock.withLock { () -> Bool in
            let value = wantsKeyframe
            wantsKeyframe = false
            return value
        }
        let properties = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: ptsNanos, timescale: 1_000_000_000),
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let packet = Self.packet(from: sample, ptsNanos: ptsNanos) else {
                self?.forceNextKeyframe()
                return
            }
            self?.onPacket?(packet)
        }
    }

    private static func packet(from sample: CMSampleBuffer, ptsNanos: Int64) -> VideoPacket? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == noErr else { return nil }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var sets: [Data] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
        }
        return VideoPacket(isKeyframe: isKeyframe, ptsNanos: ptsNanos, parameterSets: sets, avcc: avcc)
    }
}
