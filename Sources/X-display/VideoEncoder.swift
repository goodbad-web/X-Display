import Foundation
import VideoToolbox

protocol VideoEncoderDelegate: AnyObject {
    func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnit data: Data, isKeyFrame: Bool)
}

class VideoEncoder {
    weak var delegate: VideoEncoderDelegate?
    private var compressionSession: VTCompressionSession?
    
    func initialize(width: Int, height: Int) {
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
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[+] VideoEncoder initialized with H.264 Zero-Latency configuration.")
    }
    
    func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session = compressionSession else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }
    
    private func handleEncodedFrame(sampleBuffer: CMSampleBuffer) {
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
                    headerData.append(startCode)
                    headerData.append(sps, count: parameterSetSizesOut)
                    headerData.append(startCode)
                    headerData.append(pps, count: ppsSizesOut)
                    
                    delegate?.videoEncoder(self, didEncodeNALUnit: headerData + rawData, isKeyFrame: true)
                    return
                }
            }
            
            delegate?.videoEncoder(self, didEncodeNALUnit: rawData, isKeyFrame: isKeyFrame)
        }
    }
    
    deinit {
        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
        }
    }
}
