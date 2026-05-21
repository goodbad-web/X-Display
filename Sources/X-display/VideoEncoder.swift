import Foundation
import VideoToolbox
import XDisplayShared

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnit data: Data, codec: XDisplayVideoCodec, isKeyFrame: Bool)
}

enum VideoEncoderError: Error {
    case compressionSessionCreationFailed(OSStatus)
}

class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?
    private var compressionSession: VTCompressionSession?
    private var codec: XDisplayVideoCodec = .h264
    private let timingLock = NSLock()
    private let keyFrameLock = NSLock()
    private var forceNextKeyFrame = false
    private var encodeFrameCount = 0
    private var encodeFrameTotalNs: UInt64 = 0
    private var encodeFrameMaxNs: UInt64 = 0
    private var handleFrameCount = 0
    private var handleFrameTotalNs: UInt64 = 0
    private var handleFrameMaxNs: UInt64 = 0
    private var frameIndex: Int64 = 0

    func requestKeyFrame() {
        keyFrameLock.lock()
        forceNextKeyFrame = true
        keyFrameLock.unlock()
        print("[*] VideoEncoder: next frame will be forced keyframe.")
    }

    func initialize(width: Int, height: Int, codec: XDisplayVideoCodec) throws {
        invalidate()
        resetTiming()
        self.codec = codec

        let err = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.videoToolboxCodecType,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
                guard status == noErr, let sampleBuffer = sampleBuffer else { return }

                let encoder: VideoEncoder = Unmanaged.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
                encoder.handleEncodedFrame(sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )

        guard err == noErr, let session = compressionSession else {
            print("[-] Failed to create VTCompressionSession for \(codec.logName): \(err)")
            throw VideoEncoderError.compressionSessionCreationFailed(err)
        }

        // Zero-latency configuration parameters
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: codec.profileLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)

        let bitRate = targetBitRate(width: width, height: height)
        let dataRateLimit: [NSNumber] = [
            NSNumber(value: bitRate / 8),
            NSNumber(value: 1)
        ]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimit as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[+] VideoEncoder initialized with \(codec.logName) Zero-Latency configuration. bitrate=\(bitRate)bps")
    }

    func invalidate() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session = compressionSession else { return }
        keyFrameLock.lock()
        let shouldForce = forceNextKeyFrame
        forceNextKeyFrame = false
        keyFrameLock.unlock()

        var frameProperties: CFDictionary? = nil
        if shouldForce {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let framePresentationTime = nextPresentationTime()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: framePresentationTime,
            duration: CMTime(value: 1, timescale: 60),
            frameProperties: frameProperties,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            print("[-] VTCompressionSessionEncodeFrame failed: \(status)")
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: framePresentationTime)
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
        timingLock.lock()
        encodeFrameCount += 1
        encodeFrameTotalNs += elapsedNs
        encodeFrameMaxNs = max(encodeFrameMaxNs, elapsedNs)
        let shouldLog = encodeFrameCount % 60 == 0
        let averageMs = Double(encodeFrameTotalNs) / Double(encodeFrameCount) / 1_000_000.0
        let maxMs = Double(encodeFrameMaxNs) / 1_000_000.0
        timingLock.unlock()
        if shouldLog {
            let elapsedMs = Double(elapsedNs) / 1_000_000.0
            print(String(format: "[Timing] encodeFrame: %.2f ms (avg %.2f ms, max %.2f ms)", elapsedMs, averageMs, maxMs))
        }
    }

    private func nextPresentationTime() -> CMTime {
        timingLock.lock()
        let index = frameIndex
        frameIndex += 1
        timingLock.unlock()
        return CMTime(value: index, timescale: 60)
    }

    private func handleEncodedFrame(sampleBuffer: CMSampleBuffer) {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var isKeyFrame = false
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [CFDictionary],
           let attachments = attachmentsArray.first {
            let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
            if CFDictionaryContainsKey(attachments, key) == false {
                isKeyFrame = true
            }
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var bufferLength = 0
        var bufferPointer: UnsafeMutablePointer<Int8>?

        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &bufferLength, dataPointerOut: &bufferPointer)

        if let pointer = bufferPointer {
            let rawData = Data(bytes: pointer, count: bufferLength)

            let annexBFrameData = convertAVCCSampleToAnnexB(rawData)

            if isKeyFrame {
                if let headerData = parameterSetHeaderData(from: formatDescription, codec: codec) {

                    var payload = Data()
                    payload.reserveCapacity(headerData.count + annexBFrameData.count)
                    payload.append(headerData)
                    payload.append(annexBFrameData)

                    let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
                    delegate?.videoEncoder(self, didEncodeNALUnit: payload, codec: codec, isKeyFrame: true)
                    recordHandleTiming(elapsedNs)
                    return
                }
            }

            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
            delegate?.videoEncoder(self, didEncodeNALUnit: annexBFrameData, codec: codec, isKeyFrame: isKeyFrame)
            recordHandleTiming(elapsedNs)
        }
    }

    private func parameterSetHeaderData(from formatDescription: CMFormatDescription, codec: XDisplayVideoCodec) -> Data? {
        switch codec {
        case .h264:
            return h264ParameterSetHeaderData(from: formatDescription)
        case .hevc:
            return hevcParameterSetHeaderData(from: formatDescription)
        }
    }

    private func h264ParameterSetHeaderData(from formatDescription: CMFormatDescription) -> Data? {
        var spsSize = 0
        var parameterSetCount = 0
        var nalUnitHeaderLength = Int32(0)
        var spsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )

        var ppsSize = 0
        var ppsPointer: UnsafePointer<UInt8>?
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer,
            parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )

        guard let sps = spsPointer, let pps = ppsPointer else { return nil }
        return makeAnnexBHeader(parameterSets: [(sps, spsSize), (pps, ppsSize)])
    }

    private func hevcParameterSetHeaderData(from formatDescription: CMFormatDescription) -> Data? {
        var parameterSets: [(UnsafePointer<UInt8>, Int)] = []

        for index in 0..<3 {
            var parameterSetSize = 0
            var parameterSetCount = 0
            var nalUnitHeaderLength = Int32(0)
            var parameterSetPointer: UnsafePointer<UInt8>?
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &parameterSetPointer,
                parameterSetSizeOut: &parameterSetSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: &nalUnitHeaderLength
            )

            guard status == noErr, let pointer = parameterSetPointer else {
                return nil
            }
            parameterSets.append((pointer, parameterSetSize))
        }

        return makeAnnexBHeader(parameterSets: parameterSets)
    }

    private func makeAnnexBHeader(parameterSets: [(UnsafePointer<UInt8>, Int)]) -> Data {
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var headerData = Data()
        let totalSize = parameterSets.reduce(0) { $0 + startCode.count + $1.1 }
        headerData.reserveCapacity(totalSize)
        for (pointer, size) in parameterSets {
            headerData.append(startCode)
            headerData.append(pointer, count: size)
        }
        return headerData
    }

    private func convertAVCCSampleToAnnexB(_ data: Data) -> Data {
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var offset = 0
        var output = Data()

        while offset + 4 <= data.count {
            let length = data[offset..<(offset + 4)].reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }
            offset += 4

            guard length > 0, offset + Int(length) <= data.count else {
                return data
            }

            output.append(startCode)
            output.append(data[offset..<(offset + Int(length))])
            offset += Int(length)
        }

        return output.isEmpty ? data : output
    }

    private func recordHandleTiming(_ elapsedNs: UInt64) {
        timingLock.lock()
        handleFrameCount += 1
        handleFrameTotalNs += elapsedNs
        handleFrameMaxNs = max(handleFrameMaxNs, elapsedNs)
        let shouldLog = handleFrameCount % 60 == 0
        let averageMs = Double(handleFrameTotalNs) / Double(handleFrameCount) / 1_000_000.0
        let maxMs = Double(handleFrameMaxNs) / 1_000_000.0
        timingLock.unlock()
        if shouldLog {
            let elapsedMs = Double(elapsedNs) / 1_000_000.0
            print(String(format: "[Timing] handleEncodedFrame: %.2f ms (avg %.2f ms, max %.2f ms)", elapsedMs, averageMs, maxMs))
        }
    }

    private func targetBitRate(width: Int, height: Int) -> Int {
        let scaledBitRate = width * height * 12
        return min(max(scaledBitRate, 8_000_000), 50_000_000)
    }

    private func resetTiming() {
        timingLock.lock()
        encodeFrameCount = 0
        encodeFrameTotalNs = 0
        encodeFrameMaxNs = 0
        handleFrameCount = 0
        handleFrameTotalNs = 0
        handleFrameMaxNs = 0
        frameIndex = 0
        timingLock.unlock()
    }

    deinit {
        invalidate()
    }
}

private extension XDisplayVideoCodec {
    var videoToolboxCodecType: CMVideoCodecType {
        switch self {
        case .h264:
            return kCMVideoCodecType_H264
        case .hevc:
            return kCMVideoCodecType_HEVC
        }
    }

    var profileLevel: CFString {
        switch self {
        case .h264:
            return kVTProfileLevel_H264_Baseline_AutoLevel
        case .hevc:
            return kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }

    var logName: String {
        switch self {
        case .h264:
            return "H.264"
        case .hevc:
            return "HEVC"
        }
    }
}
