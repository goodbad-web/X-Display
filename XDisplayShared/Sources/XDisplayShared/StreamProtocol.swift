import Foundation

public enum XDisplayProtocol {
    public static let bonjourServiceType = "_xdisplay._tcp"
    public static let saltLength = 16
    public static let pairingVerificationToken = "SUCCESS"
    public static let rawInputEventIdentifier: UInt8 = 0x01
}

public enum XDisplayProtocolError: Error, Equatable {
    case emptyPayload
    case invalidLength
    case invalidMagic(UInt8)
    case invalidInputIdentifier(UInt8)
    case invalidVideoCodec(UInt8)
}

public enum XDisplayPayloadMagic: UInt8, Equatable {
    case pairingRequest = 0x02
    case pairingVerify = 0x03
    case pairingResult = 0x04
    case videoFrame = 0x10
    case inputEvent = 0x11
    case clientInfo = 0x12
}

public enum XDisplayVideoCodec: UInt8, Equatable, Sendable {
    case h264 = 0x01
    case hevc = 0x02
}

public struct XDisplayVideoFramePayload: Equatable, Sendable {
    public let codec: XDisplayVideoCodec
    public let data: Data

    public init(codec: XDisplayVideoCodec, data: Data) {
        self.codec = codec
        self.data = data
    }

    public func encodeRawPayload() -> Data {
        var payload = Data()
        payload.reserveCapacity(1 + data.count)
        payload.append(codec.rawValue)
        payload.append(data)
        return payload
    }

    public static func decodeRawPayload(_ payload: Data) throws -> XDisplayVideoFramePayload {
        guard let rawCodec = payload.first else {
            throw XDisplayProtocolError.invalidLength
        }
        guard let codec = XDisplayVideoCodec(rawValue: rawCodec) else {
            throw XDisplayProtocolError.invalidVideoCodec(rawCodec)
        }

        let frameData = payload.dropFirst()
        guard !frameData.isEmpty else {
            throw XDisplayProtocolError.invalidLength
        }

        return XDisplayVideoFramePayload(codec: codec, data: frameData)
    }
}

public struct XDisplayClientInfoEvent: Equatable, Sendable {
    public let isPortrait: Bool
    public let preferredCodec: XDisplayVideoCodec
    public let maxFrameRate: UInt8

    public init(isPortrait: Bool, preferredCodec: XDisplayVideoCodec = .h264, maxFrameRate: UInt8 = 60) {
        self.isPortrait = isPortrait
        self.preferredCodec = preferredCodec
        self.maxFrameRate = maxFrameRate
    }

    public func encodeRawPayload() -> Data {
        Data([isPortrait ? 1 : 0, preferredCodec.rawValue, maxFrameRate])
    }

    public static func decodeRawPayload(_ payload: Data) throws -> XDisplayClientInfoEvent {
        guard let value = payload.first else {
            throw XDisplayProtocolError.invalidLength
        }
        let isPortrait = value == 1
        
        let preferredCodec: XDisplayVideoCodec
        if payload.count >= 2 {
            preferredCodec = XDisplayVideoCodec(rawValue: payload[1]) ?? .h264
        } else {
            preferredCodec = .h264
        }
        
        let maxFrameRate: UInt8
        if payload.count >= 3 {
            maxFrameRate = payload[2]
        } else {
            maxFrameRate = 60
        }
        
        return XDisplayClientInfoEvent(isPortrait: isPortrait, preferredCodec: preferredCodec, maxFrameRate: maxFrameRate)
    }
}

public enum XDisplayPacketCodec {
    public static let lengthHeaderSize = 4

    public static func encodeLengthHeader(payloadLength: Int) -> Data {
        var length = UInt32(payloadLength).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) }
    }

    public static func decodeLengthHeader(_ data: Data) throws -> Int {
        guard data.count == lengthHeaderSize else {
            throw XDisplayProtocolError.invalidLength
        }

        let value = data.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        return Int(value)
    }

    public static func encodePacket(payload: Data) -> Data {
        var packet = Data()
        packet.reserveCapacity(lengthHeaderSize + payload.count)
        packet.append(encodeLengthHeader(payloadLength: payload.count))
        packet.append(payload)
        return packet
    }

    public static func payloadMagic(in payload: Data) throws -> XDisplayPayloadMagic {
        guard let rawMagic = payload.first else {
            throw XDisplayProtocolError.emptyPayload
        }
        guard let magic = XDisplayPayloadMagic(rawValue: rawMagic) else {
            throw XDisplayProtocolError.invalidMagic(rawMagic)
        }
        return magic
    }

    public static func payloadBody(in payload: Data, expectedMagic: XDisplayPayloadMagic) throws -> Data {
        let magic = try payloadMagic(in: payload)
        guard magic == expectedMagic else {
            throw XDisplayProtocolError.invalidMagic(payload[0])
        }
        return payload.dropFirst()
    }

    public static func makePayload(magic: XDisplayPayloadMagic, body: Data = Data()) -> Data {
        var payload = Data([magic.rawValue])
        payload.append(body)
        return payload
    }

    public static func makePairingRequest(salt: Data) -> Data {
        makePayload(magic: .pairingRequest, body: salt)
    }

    public static func decodePairingRequestSalt(_ payload: Data) throws -> Data {
        let body = try payloadBody(in: payload, expectedMagic: .pairingRequest)
        guard body.count >= XDisplayProtocol.saltLength else {
            throw XDisplayProtocolError.invalidLength
        }
        return body.prefix(XDisplayProtocol.saltLength)
    }

    public static func makePairingVerification(encryptedToken: Data) -> Data {
        makePayload(magic: .pairingVerify, body: encryptedToken)
    }

    public static func makePairingResult(success: Bool) -> Data {
        makePayload(magic: .pairingResult, body: Data([success ? 1 : 0]))
    }

    public static func decodePairingResult(_ payload: Data) throws -> Bool {
        let body = try payloadBody(in: payload, expectedMagic: .pairingResult)
        guard let status = body.first else {
            throw XDisplayProtocolError.invalidLength
        }
        return status == 1
    }

    public static func makeEncryptedVideoFrame(_ encryptedData: Data) -> Data {
        makePayload(magic: .videoFrame, body: encryptedData)
    }

    public static func decodeEncryptedVideoFrame(_ payload: Data) throws -> Data {
        try payloadBody(in: payload, expectedMagic: .videoFrame)
    }

    public static func makeEncryptedInputEvent(_ encryptedData: Data) -> Data {
        makePayload(magic: .inputEvent, body: encryptedData)
    }

    public static func decodeEncryptedInputEvent(_ payload: Data) throws -> Data {
        try payloadBody(in: payload, expectedMagic: .inputEvent)
    }

    public static func makeEncryptedClientInfo(_ encryptedData: Data) -> Data {
        makePayload(magic: .clientInfo, body: encryptedData)
    }

    public static func decodeEncryptedClientInfo(_ payload: Data) throws -> Data {
        try payloadBody(in: payload, expectedMagic: .clientInfo)
    }
}
