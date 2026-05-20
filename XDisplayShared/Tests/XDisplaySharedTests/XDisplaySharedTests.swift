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
