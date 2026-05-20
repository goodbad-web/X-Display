import Foundation

public enum XDisplayTouchPhase: UInt8, Equatable {
    case began = 0
    case moved = 1
    case ended = 2
    case cancelled = 3
}

public struct XDisplayTouchEvent: Equatable {
    public let phase: XDisplayTouchPhase
    public let x: Float
    public let y: Float
    public let pressure: Float

    public init(phase: XDisplayTouchPhase, x: Float, y: Float, pressure: Float) {
        self.phase = phase
        self.x = x
        self.y = y
        self.pressure = pressure
    }

    public func encodeRawPayload() -> Data {
        var payload = Data()
        payload.reserveCapacity(14)
        payload.append(XDisplayProtocol.rawInputEventIdentifier)
        payload.append(phase.rawValue)
        appendFloat(x, to: &payload)
        appendFloat(y, to: &payload)
        appendFloat(pressure, to: &payload)
        return payload
    }

    public static func decodeRawPayload(_ data: Data) throws -> XDisplayTouchEvent {
        guard data.count >= 14 else {
            throw XDisplayProtocolError.invalidLength
        }
        let identifier = data[0]
        guard identifier == XDisplayProtocol.rawInputEventIdentifier else {
            throw XDisplayProtocolError.invalidInputIdentifier(identifier)
        }
        guard let phase = XDisplayTouchPhase(rawValue: data[1]) else {
            throw XDisplayProtocolError.invalidMagic(data[1])
        }

        return XDisplayTouchEvent(
            phase: phase,
            x: decodeFloat(in: data, range: 2..<6),
            y: decodeFloat(in: data, range: 6..<10),
            pressure: decodeFloat(in: data, range: 10..<14)
        )
    }

    private func appendFloat(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private static func decodeFloat(in data: Data, range: Range<Data.Index>) -> Float {
        let bits = data[range].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        return Float(bitPattern: bits)
    }
}

public struct XDisplayScrollEvent: Equatable {
    public let deltaX: Float
    public let deltaY: Float

    public init(deltaX: Float, deltaY: Float) {
        self.deltaX = deltaX
        self.deltaY = deltaY
    }

    public func encodeRawPayload() -> Data {
        var payload = Data()
        payload.reserveCapacity(9)
        payload.append(0x02) // scrollEventIdentifier
        appendFloat(deltaX, to: &payload)
        appendFloat(deltaY, to: &payload)
        return payload
    }

    public static func decodeRawPayload(_ data: Data) throws -> XDisplayScrollEvent {
        guard data.count >= 9 else {
            throw XDisplayProtocolError.invalidLength
        }
        let identifier = data[0]
        guard identifier == 0x02 else {
            throw XDisplayProtocolError.invalidInputIdentifier(identifier)
        }
        return XDisplayScrollEvent(
            deltaX: decodeFloat(in: data, range: 1..<5),
            deltaY: decodeFloat(in: data, range: 5..<9)
        )
    }

    private func appendFloat(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private static func decodeFloat(in data: Data, range: Range<Data.Index>) -> Float {
        let bits = data[range].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        return Float(bitPattern: bits)
    }
}

public struct XDisplayRightClickEvent: Equatable {
    public let x: Float
    public let y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public func encodeRawPayload() -> Data {
        var payload = Data()
        payload.reserveCapacity(9)
        payload.append(0x03) // rightClickEventIdentifier
        appendFloat(x, to: &payload)
        appendFloat(y, to: &payload)
        return payload
    }

    public static func decodeRawPayload(_ data: Data) throws -> XDisplayRightClickEvent {
        guard data.count >= 9 else {
            throw XDisplayProtocolError.invalidLength
        }
        let identifier = data[0]
        guard identifier == 0x03 else {
            throw XDisplayProtocolError.invalidInputIdentifier(identifier)
        }
        return XDisplayRightClickEvent(
            x: decodeFloat(in: data, range: 1..<5),
            y: decodeFloat(in: data, range: 5..<9)
        )
    }

    private func appendFloat(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private static func decodeFloat(in data: Data, range: Range<Data.Index>) -> Float {
        let bits = data[range].reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        return Float(bitPattern: bits)
    }
}

