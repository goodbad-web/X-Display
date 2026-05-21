import Foundation
import VideoToolbox
import CoreMedia
import XDisplayShared

protocol VideoDecoderDelegate: AnyObject {
    func videoDecoder(_ decoder: VideoDecoder, didDecodeImageBuffer pixelBuffer: CVPixelBuffer)
}

class VideoDecoder {
    weak var delegate: VideoDecoderDelegate?
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let timingLock = NSLock()
    private let sessionLock = NSRecursiveLock() // Lock to secure decompressionSession & formatDescription
    private var decodeCallCount = 0
    private var decodeCallTotalNs: UInt64 = 0
    private var decodeCallMaxNs: UInt64 = 0
    private var decodedFrameCount = 0
    private var lastDecodedLogTime = Date()
    private var lastDecodedFrameCount = 0
    private var receivedFrameCount = 0
    private var currentCodec: XDisplayVideoCodec?
    private var currentVPS: Data?
    private var currentSPS: Data?
    private var currentPPS: Data?

    func decode(codec: XDisplayVideoCodec, data: Data) {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            recordDecodeTiming(DispatchTime.now().uptimeNanoseconds - start)
        }

        sessionLock.lock()
        defer { sessionLock.unlock() }

        if currentCodec != nil, currentCodec != codec {
            resetLocked()
        }
        currentCodec = codec

        receivedFrameCount += 1
        if receivedFrameCount <= 5 {
            print("[VideoDecoder] received frame #\(receivedFrameCount), codec=\(codec.displayName), bytes=\(data.count), annexB=\(data.starts(with: [0x00, 0x00, 0x00, 0x01]))")
        }

        if data.starts(with: [0x00, 0x00, 0x00, 0x01]) {
            decodeAnnexB(data, codec: codec)
            return
        }

        guard let formatDescription = formatDescription else {
            // Need a keyframe with SPS/PPS first to initialize decoder
            return
        }

        // Non-keyframe NAL unit. It's in AVCC format (contains 4-byte size header at start).
        // Let's create CMBlockBuffer and CMSampleBuffer to feed to VTDecompressionSession.
        var blockBuffer: CMBlockBuffer?
        let size = data.count

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil, // Let OS allocate contiguous memory
            blockLength: size,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: size,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let buffer = blockBuffer else { return }

        // Copy the frame data safe and contiguous into CMBlockBuffer
        status = data.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: size
            )
        }

        guard status == noErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [size]

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sBuffer = sampleBuffer else { return }

        decodeFrame(sampleBuffer: sBuffer)
    }

    private func decodeAVCC(_ data: Data) {
        guard let formatDescription = formatDescription else {
            return
        }

        var blockBuffer: CMBlockBuffer?
        let size = data.count

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: size,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: size,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let buffer = blockBuffer else { return }

        status = data.withUnsafeBytes { pointer in
            guard let baseAddress = pointer.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: size
            )
        }

        guard status == noErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSizeArray = [size]

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizeArray,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sBuffer = sampleBuffer else {
            if receivedFrameCount <= 5 {
                print("[-] CMSampleBufferCreateReady failed: \(status)")
            }
            return
        }

        decodeFrame(sampleBuffer: sBuffer)
    }

    private func decodeAnnexB(_ data: Data, codec: XDisplayVideoCodec) {
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var offsets: [Int] = []

        var searchRange = data.startIndex..<data.endIndex
        while let range = data.range(of: startCode, options: [], in: searchRange) {
            offsets.append(range.lowerBound)
            searchRange = range.upperBound..<data.endIndex
        }

        guard !offsets.isEmpty else { return }

        var parameterSets: [(type: UInt8, data: Data)] = []
        var avccFrame = Data()

        for index in offsets.indices {
            let nalStart = offsets[index] + startCode.count
            let nalEnd = index + 1 < offsets.count ? offsets[index + 1] : data.endIndex
            guard nalStart < nalEnd else { continue }

            let nal = data.subdata(in: nalStart..<nalEnd)
            guard !nal.isEmpty else { continue }

            let nalType = nalType(for: nal, codec: codec)
            if parameterSetTypes(for: codec).contains(nalType) {
                parameterSets.append((nalType, nal))
            } else {
                appendAVCCNAL(nal, to: &avccFrame)
            }
        }

        switch codec {
        case .h264:
            if let sps = parameterSets.first(where: { $0.type == 7 })?.data,
               let pps = parameterSets.first(where: { $0.type == 8 })?.data {
                configureH264Decoder(sps: sps, pps: pps)
            }
        case .hevc:
            if let vps = parameterSets.first(where: { $0.type == 32 })?.data,
               let sps = parameterSets.first(where: { $0.type == 33 })?.data,
               let pps = parameterSets.first(where: { $0.type == 34 })?.data {
                configureHEVCDecoder(vps: vps, sps: sps, pps: pps)
            }
        }

        guard !avccFrame.isEmpty else { return }
        decodeAVCC(avccFrame)
    }

    private func appendAVCCNAL(_ nal: Data, to output: inout Data) {
        var length = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(nal)
    }

    private func decodeFrame(sampleBuffer: CMSampleBuffer) {
        guard let session = decompressionSession else { return }

        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut
        ) { [weak self] (status, infoFlags, imageBuffer, taggedBuffers, presentationTimeStamp, presentationDuration) in
            guard status == noErr, let pixelBuffer = imageBuffer, let self = self else { return }
            self.recordDecodedFrame()
            self.delegate?.videoDecoder(self, didDecodeImageBuffer: pixelBuffer)
        }

        if status != noErr {
            print("[-] VTDecompressionSessionDecodeFrame failed: \(status)")
        }
    }

    private func nalType(for nal: Data, codec: XDisplayVideoCodec) -> UInt8 {
        guard let firstByte = nal.first else { return 0 }
        switch codec {
        case .h264:
            return firstByte & 0x1f
        case .hevc:
            return (firstByte >> 1) & 0x3f
        }
    }

    private func parameterSetTypes(for codec: XDisplayVideoCodec) -> Set<UInt8> {
        switch codec {
        case .h264:
            return [7, 8]
        case .hevc:
            return [32, 33, 34]
        }
    }

    private func configureH264Decoder(sps: Data, pps: Data) {
        if decompressionSession != nil, currentSPS == sps, currentPPS == pps {
            return
        }

        var newFormatDescription: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsPointer = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPointer = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return kCMFormatDescriptionError_InvalidParameter
                }

                let parameterSetPointers = [spsPointer, ppsPointer]
                let parameterSetSizes = [sps.count, pps.count]

                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &newFormatDescription
                )
            }
        }

        guard status == noErr, let format = newFormatDescription else {
            print("[-] CMVideoFormatDescription creation failed: \(status)")
            return
        }

        currentVPS = nil
        currentSPS = sps
        currentPPS = pps
        formatDescription = format
        setupDecompressionSession(format: format)
    }

    private func configureHEVCDecoder(vps: Data, sps: Data, pps: Data) {
        if decompressionSession != nil, currentVPS == vps, currentSPS == sps, currentPPS == pps {
            return
        }

        var newFormatDescription: CMVideoFormatDescription?
        let status = vps.withUnsafeBytes { vpsBytes in
            sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    guard let vpsPointer = vpsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsPointer = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsPointer = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return kCMFormatDescriptionError_InvalidParameter
                    }

                    let parameterSetPointers = [vpsPointer, spsPointer, ppsPointer]
                    let parameterSetSizes = [vps.count, sps.count, pps.count]

                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: parameterSetPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &newFormatDescription
                    )
                }
            }
        }

        guard status == noErr, let format = newFormatDescription else {
            print("[-] HEVC CMVideoFormatDescription creation failed: \(status)")
            return
        }

        currentVPS = vps
        currentSPS = sps
        currentPPS = pps
        formatDescription = format
        setupDecompressionSession(format: format)
    }

    private func setupDecompressionSession(format: CMVideoFormatDescription) {
        if decompressionSession != nil {
            VTDecompressionSessionInvalidate(decompressionSession!)
            decompressionSession = nil
        }

        // Configure output pixel buffer format as 32BGRA for seamless Metal compatibility
        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: destinationImageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("[-] VTDecompressionSessionCreate failed: \(status)")
            return
        }

        // Enable real-time / zero-latency decoding
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.decompressionSession = session
        print("[+] VTDecompressionSession initialized successfully!")
    }

    private func recordDecodeTiming(_ elapsedNs: UInt64) {
        timingLock.lock()
        decodeCallCount += 1
        decodeCallTotalNs += elapsedNs
        decodeCallMaxNs = max(decodeCallMaxNs, elapsedNs)
        let shouldLog = decodeCallCount % 60 == 0
        let averageMs = Double(decodeCallTotalNs) / Double(decodeCallCount) / 1_000_000.0
        let maxMs = Double(decodeCallMaxNs) / 1_000_000.0
        timingLock.unlock()

        if shouldLog {
            let elapsedMs = Double(elapsedNs) / 1_000_000.0
            print(String(format: "[Timing] decode: %.2f ms (avg %.2f ms, max %.2f ms)", elapsedMs, averageMs, maxMs))
        }
    }

    private func recordDecodedFrame() {
        timingLock.lock()
        decodedFrameCount += 1
        let shouldLog = decodedFrameCount % 60 == 0
        let now = Date()
        let interval = now.timeIntervalSince(lastDecodedLogTime)
        let decodedDelta = decodedFrameCount - lastDecodedFrameCount
        if shouldLog {
            lastDecodedLogTime = now
            lastDecodedFrameCount = decodedFrameCount
        }
        timingLock.unlock()

        if shouldLog {
            let decodedFPS = interval > 0 ? Double(decodedDelta) / interval : 0
            print(String(format: "[FPS] decoded: %.1f", decodedFPS))
        }
    }

    func reset() {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        resetLocked()
        print("[+] VideoDecoder reset successfully")
    }

    private func resetLocked() {
        timingLock.lock()
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        formatDescription = nil
        currentCodec = nil
        currentVPS = nil
        currentSPS = nil
        currentPPS = nil
        decodeCallCount = 0
        decodeCallTotalNs = 0
        decodeCallMaxNs = 0
        decodedFrameCount = 0
        receivedFrameCount = 0
        lastDecodedFrameCount = 0
        timingLock.unlock()
    }

    deinit {
        sessionLock.lock()
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        sessionLock.unlock()
    }
}

private extension XDisplayVideoCodec {
    var displayName: String {
        switch self {
        case .h264:
            return "H.264"
        case .hevc:
            return "HEVC"
        }
    }
}
