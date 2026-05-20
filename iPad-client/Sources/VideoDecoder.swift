import Foundation
import VideoToolbox
import CoreMedia

protocol VideoDecoderDelegate: AnyObject {
    func videoDecoder(_ decoder: VideoDecoder, didDecodeImageBuffer pixelBuffer: CVPixelBuffer)
}

class VideoDecoder {
    weak var delegate: VideoDecoderDelegate?
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let timingLock = NSLock()
    private var decodeCallCount = 0
    private var decodeCallTotalNs: UInt64 = 0
    private var decodeCallMaxNs: UInt64 = 0
    private var decodedFrameCount = 0
    private var lastDecodedLogTime = Date()
    private var lastDecodedFrameCount = 0

    func decode(data: Data) {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            recordDecodeTiming(DispatchTime.now().uptimeNanoseconds - start)
        }

        // Look for Annex-B start codes (0x00000001) to locate SPS and PPS on keyframes
        if data.starts(with: [0x00, 0x00, 0x00, 0x01]) {
            parseAnnexBHeaderAndConfigure(data: data)
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

    private func parseAnnexBHeaderAndConfigure(data: Data) {
        // Helper to locate Annex-B start codes [0x00, 0x00, 0x00, 0x01]
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var offsets: [Int] = []

        var searchRange = 0..<data.count
        while let range = data.range(of: startCode, options: [], in: searchRange) {
            offsets.append(range.lowerBound)
            searchRange = range.upperBound..<data.count
        }

        guard offsets.count >= 2 else { return }

        // Parse SPS and PPS
        let spsStart = offsets[0] + 4
        let spsEnd = offsets[1]
        let sps = data.subdata(in: spsStart..<spsEnd)

        // PPS starts after second start code. NAL unit frame follows the third start code.
        let ppsStart = offsets[1] + 4
        let ppsEnd = offsets.count > 2 ? offsets[2] : data.count
        let pps = data.subdata(in: ppsStart..<ppsEnd)

        // Build CMVideoFormatDescription from SPS/PPS parameters safely utilizing Swift scopes
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

        self.formatDescription = format
        setupDecompressionSession(format: format)

        // If there's an active frame trailing the SPS/PPS in AnnexB format, decode it as well.
        if offsets.count > 2 {
            let frameStart = offsets[2]
            let frameData = data.subdata(in: frameStart..<data.count)

            // Convert H.264 frame NAL unit from AnnexB to AVCC format (replace start code with 4-byte size)
            var avccData = Data()
            var size = UInt32(frameData.count - 4).bigEndian
            withUnsafeBytes(of: &size) { avccData.append(contentsOf: $0) }
            avccData.append(frameData.subdata(in: 4..<frameData.count))

            decode(data: avccData)
        }
    }

    private func setupDecompressionSession(format: CMVideoFormatDescription) {
        if decompressionSession != nil {
            VTDecompressionSessionInvalidate(decompressionSession!)
            decompressionSession = nil
        }

        // Configure output pixel buffer format as 32BGRA for seamless Metal compatibility
        let destinationImageBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
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

        guard status == noErr else {
            print("[-] VTDecompressionSessionCreate failed: \(status)")
            return
        }

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

    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
