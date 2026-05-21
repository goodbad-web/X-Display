import CryptoKit
import Foundation
import Testing
@testable import XDisplayShared

@Test func cryptoRoundTrip() throws {
    let salt = Data((0..<XDisplayProtocol.saltLength).map(UInt8.init))
    let key = CryptoHelper.deriveKey(pin: "1234", salt: salt)
    let source = Data("hello".utf8)

    let encrypted = try CryptoHelper.encrypt(data: source, key: key)
    let decrypted = try CryptoHelper.decrypt(combinedData: encrypted, key: key)

    #expect(decrypted == source)
}

@Test func packetLengthHeaderRoundTrip() throws {
    let payload = Data([XDisplayPayloadMagic.videoFrame.rawValue, 1, 2, 3])
    let packet = XDisplayPacketCodec.encodePacket(payload: payload)

    let length = try XDisplayPacketCodec.decodeLengthHeader(packet.prefix(4))

    #expect(length == payload.count)
    #expect(packet.dropFirst(4) == payload)
}

@Test func inputEventRoundTrip() throws {
    let source = XDisplayTouchEvent(phase: .moved, x: 0.25, y: 0.75, pressure: 0.5)

    let decoded = try XDisplayTouchEvent.decodeRawPayload(source.encodeRawPayload())

    #expect(decoded == source)
}

@Test func invalidPayloadMagicFails() throws {
    do {
        _ = try XDisplayPacketCodec.payloadMagic(in: Data([0xff]))
    } catch XDisplayProtocolError.invalidMagic(0xff) {
        return
    }

    Issue.record("Expected invalid magic failure")
}

@Test func shortInputPayloadFails() throws {
    do {
        _ = try XDisplayTouchEvent.decodeRawPayload(Data([XDisplayProtocol.rawInputEventIdentifier]))
    } catch XDisplayProtocolError.invalidLength {
        return
    }

    Issue.record("Expected invalid length failure")
}

@Test func retinaDisplayConfigurationDerivesPixelSize() throws {
    let configuration = try XDisplayDisplayConfiguration(
        logicalSize: XDisplaySize(width: 1366, height: 1024),
        scale: .retina2x,
        pixelsPerInch: 264
    )

    #expect(configuration.logicalSize == XDisplaySize(width: 1366, height: 1024))
    #expect(configuration.pixelSize == XDisplaySize(width: 2732, height: 2048))
    #expect(configuration.scale == .retina2x)
    #expect(configuration.pixelsPerInch == 264)
}

@Test func iPadAirResolutionConfigurationDerivesPixelSize() throws {
    let configuration = try XDisplayDisplayConfiguration(
        logicalSize: XDisplaySize(width: 1210, height: 834),
        scale: .retina2x,
        pixelsPerInch: 264
    )

    #expect(configuration.pixelSize == XDisplaySize(width: 2420, height: 1668))
    #expect(configuration.pixelsPerInch == 264)
}

@Test func iPadAirStandardScaleConfigurationKeepsPixelSize() throws {
    let configuration = try XDisplayDisplayConfiguration(
        logicalSize: XDisplaySize(width: 2420, height: 1668),
        scale: .standard1x,
        pixelsPerInch: 264
    )

    #expect(configuration.pixelSize == XDisplaySize(width: 2420, height: 1668))
    #expect(configuration.scale == .standard1x)
    #expect(configuration.pixelsPerInch == 264)
}

@Test func iPadPro13RetinaConfigurationDerivesPixelSize() throws {
    let configuration = try XDisplayDisplayConfiguration(
        logicalSize: XDisplaySize(width: 1376, height: 1032),
        scale: .retina2x,
        pixelsPerInch: 264
    )

    #expect(configuration.pixelSize == XDisplaySize(width: 2752, height: 2064))
    #expect(configuration.scale == .retina2x)
    #expect(configuration.pixelsPerInch == 264)
}

@Test func iPadPro13StandardScaleConfigurationKeepsPixelSize() throws {
    let configuration = try XDisplayDisplayConfiguration(
        logicalSize: XDisplaySize(width: 2752, height: 2064),
        scale: .standard1x,
        pixelsPerInch: 264
    )

    #expect(configuration.pixelSize == XDisplaySize(width: 2752, height: 2064))
    #expect(configuration.scale == .standard1x)
    #expect(configuration.pixelsPerInch == 264)
}

@Test func iPadMiniRetinaConfigurationDerivesPixelSize() throws {
    let configuration = try XDisplayDisplayConfiguration(
        logicalSize: XDisplaySize(width: 1133, height: 744),
        scale: .retina2x,
        pixelsPerInch: 326
    )

    #expect(configuration.pixelSize == XDisplaySize(width: 2266, height: 1488))
    #expect(configuration.scale == .retina2x)
    #expect(configuration.pixelsPerInch == 326)
}

@Test func iPadMiniStandardScaleConfigurationKeepsPixelSize() throws {
    let configuration = try XDisplayDisplayConfiguration(
        logicalSize: XDisplaySize(width: 2266, height: 1488),
        scale: .standard1x,
        pixelsPerInch: 326
    )

    #expect(configuration.pixelSize == XDisplaySize(width: 2266, height: 1488))
    #expect(configuration.scale == .standard1x)
    #expect(configuration.pixelsPerInch == 326)
}

@Test func standardDisplayConfigurationKeepsPixelSize() throws {
    let configuration = try XDisplayDisplayConfiguration(
        logicalSize: XDisplaySize(width: 1920, height: 1080),
        scale: .standard1x
    )

    #expect(configuration.logicalSize == XDisplaySize(width: 1920, height: 1080))
    #expect(configuration.pixelSize == XDisplaySize(width: 1920, height: 1080))
    #expect(configuration.scale == .standard1x)
}

@Test func invalidDisplayConfigurationFails() throws {
    do {
        _ = try XDisplayDisplayConfiguration(
            logicalSize: XDisplaySize(width: 1366, height: 1024),
            pixelSize: XDisplaySize(width: 1366, height: 1024),
            scale: .retina2x
        )
    } catch XDisplayDisplayConfigurationError.inconsistentPixelSize(
        expected: XDisplaySize(width: 2732, height: 2048),
        actual: XDisplaySize(width: 1366, height: 1024)
    ) {
        #expect(XDisplayScale(multiplier: 3) == nil)
        return
    }

    Issue.record("Expected invalid display configuration failure")
}

@Test func videoFramePayloadRoundTrip() throws {
    let h264 = XDisplayVideoFramePayload(codec: .h264, data: Data([1, 2, 3]))
    let hevc = XDisplayVideoFramePayload(codec: .hevc, data: Data([4, 5, 6]))

    #expect(try XDisplayVideoFramePayload.decodeRawPayload(h264.encodeRawPayload()) == h264)
    #expect(try XDisplayVideoFramePayload.decodeRawPayload(hevc.encodeRawPayload()) == hevc)
}

@Test func invalidVideoFramePayloadFails() throws {
    do {
        _ = try XDisplayVideoFramePayload.decodeRawPayload(Data())
        Issue.record("Expected invalid length failure")
    } catch XDisplayProtocolError.invalidLength {
        // Expected.
    } catch {
        Issue.record("Expected invalid length failure")
    }

    do {
        _ = try XDisplayVideoFramePayload.decodeRawPayload(Data([0xff, 1]))
    } catch XDisplayProtocolError.invalidVideoCodec(0xff) {
        return
    }

    Issue.record("Expected invalid video codec failure")
}
