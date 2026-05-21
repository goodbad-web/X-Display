import Foundation
import VideoToolbox

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnit data: Data, isKeyFrame: Bool)
}

class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?
    private var compressionSession: VTCompressionSession?
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

    func initialize(width: Int, height: Int) {
        invalidate()
        resetTiming()

        let err = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
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
            print("[-] Failed to create VTCompressionSession")
            return
        }

        // Zero-latency configuration parameters
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)

        let bitRate = targetBitRate(width: width, height: height)
        let dataRateLimit: [NSNumber] = [
            NSNumber(value: bitRate / 8),
            NSNumber(value: 1)
        ]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitRate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimit as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[+] VideoEncoder initialized with H.264 Zero-Latency configuration. bitrate=\(bitRate)bps")
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

            // Extract and prepend SPS/PPS on I-Frames for remote iOS hardware decoder compatibility
            if isKeyFrame {
                var parameterSetSizesOut = 0
                var parameterSetCountOut = 0
                var nalUnitHeaderLengthOut = Int32(0)

                // Extract SPS (Sequence Parameter Set)
                var spsPointer: UnsafePointer<UInt8>?
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: 0,
                    parameterSetPointerOut: &spsPointer,
                    parameterSetSizeOut: &parameterSetSizesOut,
                    parameterSetCountOut: &parameterSetCountOut,
                    nalUnitHeaderLengthOut: &nalUnitHeaderLengthOut
                )

                // Extract PPS (Picture Parameter Set)
                var ppsPointer: UnsafePointer<UInt8>?
                var ppsSizesOut = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription,
                    parameterSetIndex: 1,
                    parameterSetPointerOut: &ppsPointer,
                    parameterSetSizeOut: &ppsSizesOut,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )

                if let sps = spsPointer, let pps = ppsPointer {
                    let startCode = Data([0x00, 0x00, 0x00, 0x01])
                    var headerData = Data()
                    headerData.reserveCapacity((startCode.count * 2) + parameterSetSizesOut + ppsSizesOut)
                    headerData.append(startCode)
                    headerData.append(sps, count: parameterSetSizesOut)
                    headerData.append(startCode)
                    headerData.append(pps, count: ppsSizesOut)

                    var payload = Data()
                    payload.reserveCapacity(headerData.count + annexBFrameData.count)
                    payload.append(headerData)
                    payload.append(annexBFrameData)

                    let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
                    delegate?.videoEncoder(self, didEncodeNALUnit: payload, isKeyFrame: true)
                    recordHandleTiming(elapsedNs)
                    return
                }
            }

            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
            delegate?.videoEncoder(self, didEncodeNALUnit: annexBFrameData, isKeyFrame: isKeyFrame)
            recordHandleTiming(elapsedNs)
        }
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
