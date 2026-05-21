import Foundation

public struct XDisplaySize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum XDisplayScale: Equatable, Sendable {
    case standard1x
    case retina2x

    public var multiplier: Int {
        switch self {
        case .standard1x:
            return 1
        case .retina2x:
            return 2
        }
    }

    public var isHiDPI: Bool {
        self == .retina2x
    }

    public init?(multiplier: Int) {
        switch multiplier {
        case 1:
            self = .standard1x
        case 2:
            self = .retina2x
        default:
            return nil
        }
    }
}

public enum XDisplayDisplayConfigurationError: Error, Equatable {
    case invalidLogicalSize
    case invalidPixelSize
    case invalidPixelsPerInch
    case inconsistentPixelSize(expected: XDisplaySize, actual: XDisplaySize)
}

public struct XDisplayDisplayConfiguration: Equatable, Sendable {
    public let logicalSize: XDisplaySize
    public let pixelSize: XDisplaySize
    public let scale: XDisplayScale
    public let pixelsPerInch: Double

    public init(logicalSize: XDisplaySize, scale: XDisplayScale, pixelsPerInch: Double = 110.0) throws {
        try self.init(
            logicalSize: logicalSize,
            pixelSize: XDisplaySize(
                width: logicalSize.width * scale.multiplier,
                height: logicalSize.height * scale.multiplier
            ),
            scale: scale,
            pixelsPerInch: pixelsPerInch
        )
    }

    public init(logicalSize: XDisplaySize, pixelSize: XDisplaySize, scale: XDisplayScale, pixelsPerInch: Double = 110.0) throws {
        guard logicalSize.width > 0, logicalSize.height > 0 else {
            throw XDisplayDisplayConfigurationError.invalidLogicalSize
        }
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            throw XDisplayDisplayConfigurationError.invalidPixelSize
        }
        guard pixelsPerInch > 0 else {
            throw XDisplayDisplayConfigurationError.invalidPixelsPerInch
        }

        let expectedPixelSize = XDisplaySize(
            width: logicalSize.width * scale.multiplier,
            height: logicalSize.height * scale.multiplier
        )
        guard pixelSize == expectedPixelSize else {
            throw XDisplayDisplayConfigurationError.inconsistentPixelSize(
                expected: expectedPixelSize,
                actual: pixelSize
            )
        }

        self.logicalSize = logicalSize
        self.pixelSize = pixelSize
        self.scale = scale
        self.pixelsPerInch = pixelsPerInch
    }
}
