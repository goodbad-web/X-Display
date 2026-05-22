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
    /// スクロール中心の正規化座標（0.0〜1.0）。Mac側でカーソルをこの位置に移動してからwheelを投げる。
    public let x: Float
    public let y: Float

    public init(deltaX: Float, deltaY: Float, x: Float, y: Float) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.x = x
        self.y = y
    }

    // Payload: 1 (id) + 4 (deltaX) + 4 (deltaY) + 4 (x) + 4 (y) = 17 bytes
    public func encodeRawPayload() -> Data {
        var payload = Data()
        payload.reserveCapacity(17)
        payload.append(0x02) // scrollEventIdentifier
        appendFloat(deltaX, to: &payload)
        appendFloat(deltaY, to: &payload)
        appendFloat(x, to: &payload)
        appendFloat(y, to: &payload)
        return payload
    }

    public static func decodeRawPayload(_ data: Data) throws -> XDisplayScrollEvent {
        guard data.count >= 17 else {
            throw XDisplayProtocolError.invalidLength
        }
        let identifier = data[0]
        guard identifier == 0x02 else {
            throw XDisplayProtocolError.invalidInputIdentifier(identifier)
        }
        return XDisplayScrollEvent(
            deltaX: decodeFloat(in: data, range: 1..<5),
            deltaY: decodeFloat(in: data, range: 5..<9),
            x: decodeFloat(in: data, range: 9..<13),
            y: decodeFloat(in: data, range: 13..<17)
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

public struct XDisplayPencilEvent: Equatable {
    public let phase: XDisplayTouchPhase
    public let x: Float
    public let y: Float
    public let pressure: Float
    public let tiltX: Float
    public let tiltY: Float
    public let roll: Float
    public let isHover: Bool

    public init(phase: XDisplayTouchPhase, x: Float, y: Float, pressure: Float, tiltX: Float, tiltY: Float, roll: Float, isHover: Bool) {
        self.phase = phase
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.roll = roll
        self.isHover = isHover
    }

    public func encodeRawPayload() -> Data {
        var payload = Data()
        payload.reserveCapacity(28)
        payload.append(0x04) // pencilEventIdentifier
        payload.append(phase.rawValue)
        appendFloat(x, to: &payload)
        appendFloat(y, to: &payload)
        appendFloat(pressure, to: &payload)
        appendFloat(tiltX, to: &payload)
        appendFloat(tiltY, to: &payload)
        appendFloat(roll, to: &payload)
        payload.append(isHover ? 1 : 0)
        return payload
    }

    public static func decodeRawPayload(_ data: Data) throws -> XDisplayPencilEvent {
        guard data.count >= 27 else {
            throw XDisplayProtocolError.invalidLength
        }
        let identifier = data[0]
        guard identifier == 0x04 else {
            throw XDisplayProtocolError.invalidInputIdentifier(identifier)
        }
        guard let phase = XDisplayTouchPhase(rawValue: data[1]) else {
            throw XDisplayProtocolError.invalidMagic(data[1])
        }

        return XDisplayPencilEvent(
            phase: phase,
            x: decodeFloat(in: data, range: 2..<6),
            y: decodeFloat(in: data, range: 6..<10),
            pressure: decodeFloat(in: data, range: 10..<14),
            tiltX: decodeFloat(in: data, range: 14..<18),
            tiltY: decodeFloat(in: data, range: 18..<22),
            roll: decodeFloat(in: data, range: 22..<26),
            isHover: data[26] != 0
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

public enum XDisplayPencilInteractionType: UInt8, Equatable {
    case doubleTap = 0
    case squeeze = 1
}

public struct XDisplayPencilInteractionEvent: Equatable {
    public let type: XDisplayPencilInteractionType

    public init(type: XDisplayPencilInteractionType) {
        self.type = type
    }

    public func encodeRawPayload() -> Data {
        var payload = Data()
        payload.reserveCapacity(2)
        payload.append(0x05) // pencilInteractionEventIdentifier
        payload.append(type.rawValue)
        return payload
    }

    public static func decodeRawPayload(_ data: Data) throws -> XDisplayPencilInteractionEvent {
        guard data.count >= 2 else {
            throw XDisplayProtocolError.invalidLength
        }
        let identifier = data[0]
        guard identifier == 0x05 else {
            throw XDisplayProtocolError.invalidInputIdentifier(identifier)
        }
        guard let type = XDisplayPencilInteractionType(rawValue: data[1]) else {
            throw XDisplayProtocolError.invalidMagic(data[1])
        }
        return XDisplayPencilInteractionEvent(type: type)
    }
}

public struct XDisplayKeyboardEvent: Equatable {
    public let keyCode: UInt16
    public let isDown: Bool
    public let modifierFlags: UInt64

    public init(keyCode: UInt16, isDown: Bool, modifierFlags: UInt64) {
        self.keyCode = keyCode
        self.isDown = isDown
        self.modifierFlags = modifierFlags
    }

    // Payload: 1 (id: 0x06) + 2 (keyCode) + 1 (isDown) + 8 (modifierFlags) = 12 bytes
    public func encodeRawPayload() -> Data {
        var payload = Data()
        payload.reserveCapacity(12)
        payload.append(0x06) // keyboardEventIdentifier
        
        var key = keyCode.bigEndian
        withUnsafeBytes(of: &key) { payload.append(contentsOf: $0) }
        
        payload.append(isDown ? 1 : 0)
        
        var modifiers = modifierFlags.bigEndian
        withUnsafeBytes(of: &modifiers) { payload.append(contentsOf: $0) }
        
        return payload
    }

    public static func decodeRawPayload(_ data: Data) throws -> XDisplayKeyboardEvent {
        guard data.count >= 12 else {
            throw XDisplayProtocolError.invalidLength
        }
        let identifier = data[0]
        guard identifier == 0x06 else {
            throw XDisplayProtocolError.invalidInputIdentifier(identifier)
        }
        
        let key = data[1...2].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        let isDown = data[3] != 0
        
        let modifiers = data[4...11].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        
        return XDisplayKeyboardEvent(keyCode: key, isDown: isDown, modifierFlags: modifiers)
    }
}

public struct XDisplayMouseEvent: Equatable {
    public let type: UInt8 // 0: Move, 1: ButtonDown, 2: ButtonUp
    public let buttonNumber: UInt8 // 0: Left, 1: Right, 2: Middle/Other
    public let deltaX: Float
    public let deltaY: Float
    public let x: Float
    public let y: Float

    public init(type: UInt8, buttonNumber: UInt8, deltaX: Float, deltaY: Float, x: Float, y: Float) {
        self.type = type
        self.buttonNumber = buttonNumber
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.x = x
        self.y = y
    }

    // Payload: 1 (id: 0x07) + 1 (type) + 1 (buttonNumber) + 4 (deltaX) + 4 (deltaY) + 4 (x) + 4 (y) = 19 bytes
    public func encodeRawPayload() -> Data {
        var payload = Data()
        payload.reserveCapacity(19)
        payload.append(0x07) // mouseEventIdentifier
        payload.append(type)
        payload.append(buttonNumber)
        appendFloat(deltaX, to: &payload)
        appendFloat(deltaY, to: &payload)
        appendFloat(x, to: &payload)
        appendFloat(y, to: &payload)
        return payload
    }

    public static func decodeRawPayload(_ data: Data) throws -> XDisplayMouseEvent {
        guard data.count >= 19 else {
            throw XDisplayProtocolError.invalidLength
        }
        let identifier = data[0]
        guard identifier == 0x07 else {
            throw XDisplayProtocolError.invalidInputIdentifier(identifier)
        }
        return XDisplayMouseEvent(
            type: data[1],
            buttonNumber: data[2],
            deltaX: decodeFloat(in: data, range: 3..<7),
            deltaY: decodeFloat(in: data, range: 7..<11),
            x: decodeFloat(in: data, range: 11..<15),
            y: decodeFloat(in: data, range: 15..<19)
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
