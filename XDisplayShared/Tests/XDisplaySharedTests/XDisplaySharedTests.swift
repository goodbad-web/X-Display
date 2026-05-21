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
        scale: .retina2x
    )

    #expect(configuration.logicalSize == XDisplaySize(width: 1366, height: 1024))
    #expect(configuration.pixelSize == XDisplaySize(width: 2732, height: 2048))
    #expect(configuration.scale == .retina2x)
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
