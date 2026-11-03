import CoreMedia
import Foundation

/// One encoded H.264 frame on the wire: [flags: 1][pts in ns: 8] then, for keyframes,
/// [set count: 1] and [length: 2][bytes] per parameter set, then the frame's data.
struct VideoPacket {
    var isKeyframe: Bool
    var ptsNanos: Int64
    var parameterSets: [Data]
    var avcc: Data

    func encoded() -> Data {
        var out = Data(capacity: avcc.count + 64)
        out.append(isKeyframe ? 1 : 0)
        let pts = UInt64(bitPattern: ptsNanos)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(pts >> UInt64(shift) & 0xff))
        }
        if isKeyframe {
            out.append(UInt8(parameterSets.count))
            for set in parameterSets {
                out.append(UInt8(set.count >> 8 & 0xff))
                out.append(UInt8(set.count & 0xff))
                out.append(set)
            }
        }
        out.append(avcc)
        return out
    }

    init(isKeyframe: Bool, ptsNanos: Int64, parameterSets: [Data], avcc: Data) {
        self.isKeyframe = isKeyframe
        self.ptsNanos = ptsNanos
        self.parameterSets = parameterSets
        self.avcc = avcc
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 9 else { return nil }
        isKeyframe = bytes[0] & 1 == 1
        var pts: UInt64 = 0
        for i in 1...8 { pts = pts << 8 | UInt64(bytes[i]) }
        ptsNanos = Int64(bitPattern: pts)
        var offset = 9
        parameterSets = []
        if isKeyframe {
            guard bytes.count > offset else { return nil }
            let count = Int(bytes[offset])
            offset += 1
            for _ in 0..<count {
                guard bytes.count >= offset + 2 else { return nil }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard bytes.count >= offset + length else { return nil }
                parameterSets.append(Data(bytes[offset..<offset + length]))
                offset += length
            }
        }
        avcc = Data(bytes[offset...])
    }

    func makeFormatDescription() -> CMFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let copies = parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = parameterSets.map { $0.count }
        var format: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &format)
        return status == noErr ? format : nil
    }

    func makeSampleBuffer(format: CMFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard !avcc.isEmpty, CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: raw.count)
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsNanos, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}
