#if os(macOS)
import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
#if canImport(CVirtualDisplay)
import CVirtualDisplay
#endif
import CoreMedia
#if canImport(Sparkle)
import Sparkle
#endif
import XDisplayShared

struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

private struct PendingVideoFrame {
    let pixelBuffer: SendablePixelBuffer
    let presentationTime: CMTime
}

final class ScreenCaptureManager: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate, VideoEncoderDelegate, StreamServerDelegate {
    private var stream: SCStream?
    private let encoder = VideoEncoder()
    private let server = StreamServer()
    private let captureQueue = DispatchQueue(label: "com.xdisplay.capture-queue", qos: .userInteractive)
    private let fallbackCaptureQueue = DispatchQueue(label: "com.xdisplay.fallback-capture-queue", qos: .userInteractive)
    private var fallbackCaptureTimer: DispatchSourceTimer?
    private var displayID: CGDirectDisplayID?
    private var didRequestScreenCaptureAccess = false
    private var isCaptureActive = false
    private var isRestartingStream = false
    private var lastSCStreamSampleTime = Date.distantPast
    private var lastUsableFrameTime = Date.distantPast
    private var lastFrameStatus: SCFrameStatus?
    private var streamRestartCount = 0
    private var streamHealthTimer: DispatchSourceTimer?
    private var lastStreamRestartTime = Date.distantPast
    private var captureConfiguration: XDisplayDisplayConfiguration?
    private var preferredVirtualDisplayID: CGDirectDisplayID?

    // Keep only the newest pending frame so latency does not grow under load.
    private let encodeQueue = DispatchQueue(label: "com.xdisplay.encode-queue", qos: .userInteractive)
    private var isEncodeWorkerRunning = false
    private var pendingFrame: PendingVideoFrame?
    private var latestFrame: PendingVideoFrame?
    private let encodingLock = NSLock()
    private var capturedFrameCount = 0
    private var submittedFrameCount = 0
    private var replacedFrameCount = 0
    private var lastStatsTime = Date()
    private var lastCapturedFrameCount = 0
    private var lastSubmittedFrameCount = 0
    private var lastReplacedFrameCount = 0
    private var receivedSampleBufferCount = 0
    private var broadcastFrameCount = 0
    private var fallbackFrameCount = 0

    private func requestScreenCaptureAccessIfNeeded() async {
        if CGPreflightScreenCaptureAccess() {
            return
        }

        if !didRequestScreenCaptureAccess {
            didRequestScreenCaptureAccess = true
            _ = CGRequestScreenCaptureAccess()
        }

        // macOS may take a moment to propagate Screen Recording permission after a quit/reopen cycle.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    func startCaptureOfVirtualDisplay(configuration: XDisplayDisplayConfiguration, codec: XDisplayVideoCodec, virtualDisplayID: CGDirectDisplayID?) async throws {
        do {
            await requestScreenCaptureAccessIfNeeded()
            let pixelSize = configuration.pixelSize

            print("[*] Starting StreamServer...")
            server.delegate = self
            try server.start(port: 12345)

            print("[*] Initializing VideoEncoder...")
            encoder.delegate = self
            try encoder.initialize(width: pixelSize.width, height: pixelSize.height, codec: codec)

            resetCaptureStats()
            isCaptureActive = true
            captureConfiguration = configuration
            preferredVirtualDisplayID = virtualDisplayID

            try await startSCStream(configuration: configuration, virtualDisplayID: virtualDisplayID)
            startStreamHealthMonitor()
        } catch {
            print("[-] SCStream start failed: \(error.localizedDescription)")
            logScreenCaptureAccessHintIfNeeded(for: error)
            stream = nil
            cleanupStreamingResources()
            throw error
        }
    }

    private func logScreenCaptureAccessHintIfNeeded(for error: Error) {
        let description = error.localizedDescription
        guard description.localizedCaseInsensitiveContains("TCC") ||
              description.localizedCaseInsensitiveContains("declined") ||
              description.localizedCaseInsensitiveContains("screen") && description.localizedCaseInsensitiveContains("capture") else {
            return
        }

        print("""
        [!] Screen Recording permission is required for X-Display capture.
            1. Open System Settings > Privacy & Security > Screen & System Audio Recording.
            2. Enable X-Display, then quit and reopen the app.
            3. If it was already enabled but this error persists, reset stale TCC entries:
               tccutil reset ScreenCapture com.goodbad-web.X-Display
               Then grant permission again from System Settings.
        """)
    }

    func stopCapture(keepServer: Bool = false) async {
        isCaptureActive = false
        stopStreamHealthMonitor()
        stopFallbackCapture()

        if let stream {
            do {
                try await stream.stopCapture()
                print("[+] SCStream stopped.")
            } catch {
                print("[-] SCStream stop failed: \(error.localizedDescription)")
            }
        }
        self.stream = nil
        cleanupStreamingResources(keepServer: keepServer)
    }

    private func cleanupStreamingResources(keepServer: Bool = false) {
        if !keepServer {
            server.stop()
        }
        encoder.invalidate()
        isCaptureActive = false
        isRestartingStream = false
        stopStreamHealthMonitor()
        stopFallbackCapture()
        clearBufferedFrames()
        captureConfiguration = nil
        preferredVirtualDisplayID = nil
        displayID = nil
    }

    // SCStreamOutput callback
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        let now = Date()
        let status = frameStatus(from: sampleBuffer)
        lastSCStreamSampleTime = now
        lastFrameStatus = status

        guard status == nil || status == .complete || status == .started else {
            if status == .blank || status == .suspended || status == .stopped {
                print("[-] SCStream unhealthy frame status: \(statusDescription(status))")
                scheduleSCStreamRestart(reason: "frame status \(statusDescription(status))")
            }
            return
        }

        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            receivedSampleBufferCount += 1
            lastUsableFrameTime = now
            if receivedSampleBufferCount <= 5 {
                print("[Capture] sample #\(receivedSampleBufferCount), status=\(statusDescription(status)), paired=\(server.hasActivePairedConnections), size=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
            }

            let frame = PendingVideoFrame(
                pixelBuffer: SendablePixelBuffer(buffer: pixelBuffer),
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
            storeLatestFrame(frame)

            guard server.hasActivePairedConnections else {
                return
            }

            enqueueLatestFrame(frame)
        }

        logCaptureStatsIfNeeded()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[-] SCStream stopped with error: \(error.localizedDescription)")
        captureQueue.async { [weak self] in
            self?.scheduleSCStreamRestart(reason: "delegate error: \(error.localizedDescription)")
        }
    }

    private func resolveTargetDisplay(configuration: XDisplayDisplayConfiguration, virtualDisplayID: CGDirectDisplayID?) async throws -> SCDisplay {
        print("[*] Retrieving shareable content...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pixelSize = configuration.pixelSize

        // Prefer the exact virtual display ID; fall back to resolution for older/private API failures.
        let targetDisplay = content.displays.first(where: { display in
            if let virtualDisplayID, virtualDisplayID != kCGNullDirectDisplay {
                return display.displayID == virtualDisplayID
            }
            return false
        }) ?? content.displays.first(where: { Int($0.width) == pixelSize.width && Int($0.height) == pixelSize.height })

        guard let targetDisplay else {
            print("[-] Target virtual display not found. Please ensure it is created.")
            throw NSError(domain: "ScreenCaptureManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Target virtual display not found."])
        }

        displayID = targetDisplay.displayID
        print("[+] Target display found! ID: \(targetDisplay.displayID) Resolution: \(Int(targetDisplay.width))x\(Int(targetDisplay.height))")
        return targetDisplay
    }

    private func makeStreamConfiguration(configuration: XDisplayDisplayConfiguration) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = configuration.pixelSize.width
        config.height = configuration.pixelSize.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = false
        return config
    }

    private func startSCStream(configuration: XDisplayDisplayConfiguration, virtualDisplayID: CGDirectDisplayID?) async throws {
        let targetDisplay = try await resolveTargetDisplay(configuration: configuration, virtualDisplayID: virtualDisplayID)
        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        let config = makeStreamConfiguration(configuration: configuration)

        print("[*] Initializing SCStream...")
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

        print("[*] Starting SCStream capture...")
        try await newStream.startCapture()

        stream = newStream
        lastSCStreamSampleTime = Date()
        lastUsableFrameTime = Date.distantPast
        lastFrameStatus = nil
        print("[+] SCStream started successfully! Capturing frames...")
    }

    private func stopCurrentSCStream() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
            print("[+] SCStream stopped for restart.")
        } catch {
            print("[-] SCStream restart stop failed: \(error.localizedDescription)")
        }
        self.stream = nil
    }

    private func startStreamHealthMonitor() {
        stopStreamHealthMonitor()

        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.checkStreamHealth()
        }
        streamHealthTimer = timer
        timer.resume()
    }

    private func stopStreamHealthMonitor() {
        streamHealthTimer?.cancel()
        streamHealthTimer = nil
    }

    private func checkStreamHealth() {
        guard isCaptureActive, server.hasActivePairedConnections else { return }

        if let lastFrameStatus, lastFrameStatus == .blank || lastFrameStatus == .suspended || lastFrameStatus == .stopped {
            scheduleSCStreamRestart(reason: "health status \(statusDescription(lastFrameStatus))")
            return
        }

        let secondsSinceSample = Date().timeIntervalSince(lastSCStreamSampleTime)
        if secondsSinceSample > 2.0 {
            scheduleSCStreamRestart(reason: String(format: "no SCStream callback for %.1fs", secondsSinceSample))
        }
    }

    private func scheduleSCStreamRestart(reason: String) {
        guard isCaptureActive, !isRestartingStream else { return }

        let now = Date()
        guard now.timeIntervalSince(lastStreamRestartTime) >= 1.0 else { return }
        guard let configuration = captureConfiguration else { return }

        isRestartingStream = true
        lastStreamRestartTime = now
        streamRestartCount += 1
        stopFallbackCapture()
        print("[*] Restarting SCStream #\(streamRestartCount): \(reason)")

        Task { [weak self] in
            guard let self else { return }
            await self.stopCurrentSCStream()

            do {
                try await self.startSCStream(configuration: configuration, virtualDisplayID: self.preferredVirtualDisplayID)
                self.encoder.requestKeyFrame()
                self.captureQueue.async {
                    self.isRestartingStream = false
                    print("[+] SCStream restart completed.")
                }
            } catch {
                self.captureQueue.async {
                    self.isRestartingStream = false
                    print("[-] SCStream restart failed: \(error.localizedDescription)")
                    self.startFallbackCaptureIfNeeded(configuration: configuration)
                }
            }
        }
    }

    private func frameStatus(from sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else {
            return nil
        }
        return SCFrameStatus(rawValue: rawStatus)
    }

    private func statusDescription(_ status: SCFrameStatus?) -> String {
        guard let status else { return "unknown" }
        switch status {
        case .complete:
            return "complete"
        case .idle:
            return "idle"
        case .blank:
            return "blank"
        case .suspended:
            return "suspended"
        case .started:
            return "started"
        case .stopped:
            return "stopped"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    private func startFallbackCaptureIfNeeded(configuration: XDisplayDisplayConfiguration) {
        stopFallbackCapture()
        let pixelSize = configuration.pixelSize
        print("[FallbackCapture] enabled after SCStream restart failure; cursor is not included in fallback frames.")

        let timer = DispatchSource.makeTimerSource(queue: fallbackCaptureQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            self?.captureFallbackFrameIfNeeded(width: pixelSize.width, height: pixelSize.height)
        }
        fallbackCaptureTimer = timer
        timer.resume()
    }

    private func stopFallbackCapture() {
        fallbackCaptureTimer?.cancel()
        fallbackCaptureTimer = nil
    }

    private func captureFallbackFrameIfNeeded(width: Int, height: Int) {
        guard server.hasActivePairedConnections,
              !isRestartingStream,
              let displayID = displayID,
              displayID != kCGNullDirectDisplay,
              let image = CGDisplayCreateImage(displayID),
              let pixelBuffer = makePixelBuffer(from: image, width: width, height: height) else {
            return
        }

        fallbackFrameCount += 1
        if fallbackFrameCount <= 5 {
            print("[FallbackCapture] frame #\(fallbackFrameCount), size=\(width)x\(height)")
        }

        enqueueLatestFrame(
            PendingVideoFrame(
                pixelBuffer: SendablePixelBuffer(buffer: pixelBuffer),
                presentationTime: CMClockGetTime(CMClockGetHostTimeClock())
            )
        )
    }

    private func makePixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    private func storeLatestFrame(_ frame: PendingVideoFrame) {
        encodingLock.lock()
        latestFrame = frame
        encodingLock.unlock()
    }

    private func clearBufferedFrames() {
        encodingLock.lock()
        latestFrame = nil
        pendingFrame = nil
        isEncodeWorkerRunning = false
        encodingLock.unlock()
    }

    private func submitLatestFrameAsKeyFrame() {
        encoder.requestKeyFrame()

        encodingLock.lock()
        let frame = latestFrame
        encodingLock.unlock()

        guard let frame else {
            print("[-] No captured frame available yet for immediate keyframe.")
            return
        }

        enqueueLatestFrame(frame)
    }

    private func enqueueLatestFrame(_ frame: PendingVideoFrame) {
        var shouldStartWorker = false

        encodingLock.lock()
        capturedFrameCount += 1
        if isEncodeWorkerRunning {
            pendingFrame = frame
            replacedFrameCount += 1
        } else {
            isEncodeWorkerRunning = true
            shouldStartWorker = true
        }
        encodingLock.unlock()

        guard shouldStartWorker else { return }
        encodeQueue.async { [weak self] in
            self?.drainEncodeQueue(startingWith: frame)
        }
    }

    private func drainEncodeQueue(startingWith frame: PendingVideoFrame) {
        var nextFrame: PendingVideoFrame? = frame

        while let frameToEncode = nextFrame {
            encoder.encode(pixelBuffer: frameToEncode.pixelBuffer.buffer, presentationTime: frameToEncode.presentationTime)

            encodingLock.lock()
            submittedFrameCount += 1
            nextFrame = pendingFrame
            pendingFrame = nil
            if nextFrame == nil {
                isEncodeWorkerRunning = false
            }
            encodingLock.unlock()
        }
    }

    private func resetCaptureStats() {
        encodingLock.lock()
        capturedFrameCount = 0
        submittedFrameCount = 0
        replacedFrameCount = 0
        lastCapturedFrameCount = 0
        lastSubmittedFrameCount = 0
        lastReplacedFrameCount = 0
        receivedSampleBufferCount = 0
        broadcastFrameCount = 0
        fallbackFrameCount = 0
        lastSCStreamSampleTime = Date.distantPast
        lastUsableFrameTime = Date.distantPast
        lastFrameStatus = nil
        streamRestartCount = 0
        lastStreamRestartTime = Date.distantPast
        lastStatsTime = Date()
        encodingLock.unlock()
    }

    private func logCaptureStatsIfNeeded() {
        encodingLock.lock()
        let captured = capturedFrameCount
        guard captured > 0, captured % 60 == 0 else {
            encodingLock.unlock()
            return
        }

        let submitted = submittedFrameCount
        let replaced = replacedFrameCount
        let now = Date()
        let interval = now.timeIntervalSince(lastStatsTime)
        let capturedDelta = captured - lastCapturedFrameCount
        let submittedDelta = submitted - lastSubmittedFrameCount
        let replacedDelta = replaced - lastReplacedFrameCount
        lastCapturedFrameCount = captured
        lastSubmittedFrameCount = submitted
        lastReplacedFrameCount = replaced
        lastStatsTime = now
        encodingLock.unlock()

        guard interval > 0 else { return }
        print(String(
            format: "[FPS] capture: %.1f | encode-submit: %.1f | latest-replaced: %d",
            Double(capturedDelta) / interval,
            Double(submittedDelta) / interval,
            replacedDelta
        ))
    }

    // VideoEncoderDelegate callback
    func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnit data: Data, codec: XDisplayVideoCodec, isKeyFrame: Bool) {
        broadcastFrameCount += 1
        if broadcastFrameCount <= 5 {
            print("[Broadcast] frame #\(broadcastFrameCount), codec=\(codec.displayName), key=\(isKeyFrame), bytes=\(data.count)")
        }
        // Broadcast codec-tagged Annex-B video data to all connected clients.
        server.broadcast(data: data, codec: codec)
    }

    // StreamServerDelegate callbacks
    func streamServer(_ server: StreamServer, didGeneratePIN pin: String) {
        Task { @MainActor in
            // Close any existing X-Display PIN window first to prevent duplication
            for window in NSApp.windows {
                if window.title == "X-Display PIN" {
                    window.close()
                }
            }
            
            let width: CGFloat = 320
            let height: CGFloat = 180
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "X-Display PIN"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.center()
            
            // Premium dark theme matching the app's style
            window.backgroundColor = NSColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1.0)
            
            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            
            // Title Label
            let titleLabel = NSTextField(labelWithString: "iPad Connection Request")
            titleLabel.textColor = .white
            titleLabel.font = NSFont.boldSystemFont(ofSize: 16)
            titleLabel.alignment = .center
            titleLabel.frame = NSRect(x: 10, y: 130, width: width - 20, height: 24)
            container.addSubview(titleLabel)
            
            // Instruction Label
            let infoLabel = NSTextField(labelWithString: "Enter this PIN on your iPad:")
            infoLabel.textColor = .lightGray
            infoLabel.font = NSFont.systemFont(ofSize: 13)
            infoLabel.alignment = .center
            infoLabel.frame = NSRect(x: 10, y: 100, width: width - 20, height: 20)
            container.addSubview(infoLabel)
            
            // Big Beautiful PIN Label (matching the app's indigo style)
            let pinLabel = NSTextField(labelWithString: pin)
            pinLabel.textColor = NSColor(red: 0.38, green: 0.44, blue: 0.96, alpha: 1.0)
            pinLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 38, weight: .bold)
            pinLabel.alignment = .center
            pinLabel.frame = NSRect(x: 10, y: 35, width: width - 20, height: 46)
            container.addSubview(pinLabel)
            
            window.contentView = container
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func streamServerDidCompletePairing(_ server: StreamServer) {
        print("[+] Client pairing complete – forcing immediate keyframe.")
        submitLatestFrameAsKeyFrame()
    }

    private func pointInDisplay(x: Float, y: Float) -> CGPoint? {
        guard let displayID = self.displayID,
              let configuration = captureConfiguration else {
            return nil
        }

        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 && bounds.height > 0 else { return nil }

        let clampedX = CGFloat(max(0, min(1, x)))
        let clampedY = CGFloat(max(0, min(1, y)))
        return CGPoint(
            x: bounds.origin.x + clampedX * CGFloat(configuration.logicalSize.width),
            y: bounds.origin.y + clampedY * CGFloat(configuration.logicalSize.height)
        )
    }

    func streamServer(_ server: StreamServer, didReceiveInputEvent phase: UInt8, x: Float, y: Float, pressure: Float) {
        guard let point = pointInDisplay(x: x, y: y) else { return }

        var mouseType: CGEventType
        let mouseButton: CGMouseButton = .left

        switch phase {
        case 0: // Began
            mouseType = .leftMouseDown
        case 1: // Moved / Dragged
            mouseType = .leftMouseDragged
        case 2: // Ended
            mouseType = .leftMouseUp
        case 3: // Cancelled
            mouseType = .leftMouseUp
        default:
            return
        }

        // Generate and post the system mouse event to simulate user input
        guard let event = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: mouseButton) else { return }
        event.post(tap: .cghidEventTap)
    }

    func streamServer(_ server: StreamServer, didReceiveScrollEvent deltaX: Float, deltaY: Float, x: Float, y: Float) {
        // スクロール前にカーソルをiPad上のスクロール位置へ移動し、正しいウィンドウへwheelを届ける
        let point = pointInDisplay(x: x, y: y)
        if let point = point {
            CGWarpMouseCursorPosition(point)
        }

        let scrollMultiplier: Float = 0.5
        let vScroll = Int32(deltaY * scrollMultiplier)
        let hScroll = Int32(deltaX * scrollMultiplier)

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: vScroll,
            wheel2: hScroll,
            wheel3: 0
        ) else { return }

        if let point = point {
            event.location = point
        }

        event.post(tap: CGEventTapLocation.cghidEventTap)
    }


    func streamServer(_ server: StreamServer, didReceiveRightClickEvent x: Float, y: Float) {
        guard let point = pointInDisplay(x: x, y: y) else { return }
        
        guard let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDown,
            mouseCursorPosition: point,
            mouseButton: .right
        ) else { return }
        
        guard let upEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseUp,
            mouseCursorPosition: point,
            mouseButton: .right
        ) else { return }
        
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
    }

    func streamServer(_ server: StreamServer, didReceivePencilEvent event: XDisplayPencilEvent) {
        guard let point = pointInDisplay(x: event.x, y: event.y) else { return }

        let mouseType: CGEventType
        if event.isHover {
            mouseType = .mouseMoved
        } else {
            switch event.phase {
            case .began:
                mouseType = .leftMouseDown
            case .moved:
                mouseType = .leftMouseDragged
            case .ended, .cancelled:
                mouseType = .leftMouseUp
            }
        }

        guard let cgEvent = CGEvent(mouseEventSource: nil, mouseType: mouseType, mouseCursorPosition: point, mouseButton: .left) else { return }
        
        if !event.isHover {
            cgEvent.setDoubleValueField(CGEventField.tabletEventPointPressure, value: Double(event.pressure))
            cgEvent.setDoubleValueField(CGEventField.tabletEventTiltX, value: Double(event.tiltX))
            cgEvent.setDoubleValueField(CGEventField.tabletEventTiltY, value: Double(event.tiltY))
            cgEvent.setDoubleValueField(CGEventField.tabletEventRotation, value: Double(event.roll * 180.0 / .pi))
            cgEvent.setIntegerValueField(CGEventField.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        } else {
            cgEvent.setIntegerValueField(CGEventField.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            cgEvent.setDoubleValueField(CGEventField.tabletEventPointPressure, value: 0.0)
        }
        
        cgEvent.post(tap: CGEventTapLocation.cghidEventTap)
    }

    func streamServer(_ server: StreamServer, didReceivePencilInteractionEvent event: XDisplayPencilInteractionEvent) {
        switch event.type {
        case .doubleTap:
            postKeyboardEvent(keyCode: 0x30, flags: []) // Tab key (0x30)
        case .squeeze:
            postKeyboardEvent(keyCode: 0x06, flags: [.maskCommand]) // Z key (0x06) + Cmd
        }
    }
    
    private func postKeyboardEvent(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        guard let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
        
        downEvent.flags = flags
        upEvent.flags = flags
        
        downEvent.post(tap: .cghidEventTap)
        upEvent.post(tap: .cghidEventTap)
    }


}

@MainActor
class XDisplayAppManager: NSObject, NSApplicationDelegate {
    private struct DisplayResolutionPreset {
        let title: String
        let configuration: XDisplayDisplayConfiguration
    }

    private var statusItem: NSStatusItem?
    private let helper = CVirtualDisplayHelper.shared()
    private let captureManager = ScreenCaptureManager()

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private var isDisplayActive = false
    private var selectedConfiguration = XDisplayAppManager.makeConfiguration(
        logicalWidth: 1920,
        logicalHeight: 1080,
        scale: .standard1x
    )
    private var selectedCodec: XDisplayVideoCodec = .h264

    private static let resolutionPresets: [DisplayResolutionPreset] = [
        // Landscape
        DisplayResolutionPreset(title: "1920 x 1080 @1x (16:9)", configuration: makeConfiguration(logicalWidth: 1920, logicalHeight: 1080, scale: .standard1x)),
        DisplayResolutionPreset(title: "2048 x 1536 @1x (4:3)", configuration: makeConfiguration(logicalWidth: 2048, logicalHeight: 1536, scale: .standard1x)),
        DisplayResolutionPreset(title: "2266 x 1488 @1x (iPad mini, 326 ppi)", configuration: makeConfiguration(logicalWidth: 2266, logicalHeight: 1488, scale: .standard1x, pixelsPerInch: 326)),
        DisplayResolutionPreset(title: "2420 x 1668 @1x (264 ppi)", configuration: makeConfiguration(logicalWidth: 2420, logicalHeight: 1668, scale: .standard1x, pixelsPerInch: 264)),
        DisplayResolutionPreset(title: "1133 x 744 @2x (2266 x 1488, iPad mini)", configuration: makeConfiguration(logicalWidth: 1133, logicalHeight: 744, scale: .retina2x, pixelsPerInch: 326)),
        DisplayResolutionPreset(title: "1194 x 834 @2x (iPad Pro 11\")", configuration: makeConfiguration(logicalWidth: 1194, logicalHeight: 834, scale: .retina2x)),
        DisplayResolutionPreset(title: "1210 x 834 @2x (2420 x 1668, 264 ppi)", configuration: makeConfiguration(logicalWidth: 1210, logicalHeight: 834, scale: .retina2x, pixelsPerInch: 264)),
        DisplayResolutionPreset(title: "1366 x 1024 @2x (iPad Pro 12.9\")", configuration: makeConfiguration(logicalWidth: 1366, logicalHeight: 1024, scale: .retina2x)),
        DisplayResolutionPreset(title: "1376 x 1032 @2x (2752 x 2064, iPad Pro 13\")", configuration: makeConfiguration(logicalWidth: 1376, logicalHeight: 1032, scale: .retina2x, pixelsPerInch: 264)),
        DisplayResolutionPreset(title: "2752 x 2064 @1x (iPad Pro 13\")", configuration: makeConfiguration(logicalWidth: 2752, logicalHeight: 2064, scale: .standard1x, pixelsPerInch: 264)),

        // Portrait
        DisplayResolutionPreset(title: "1080 x 1920 @1x (16:9 Portrait)", configuration: makeConfiguration(logicalWidth: 1080, logicalHeight: 1920, scale: .standard1x)),
        DisplayResolutionPreset(title: "1536 x 2048 @1x (4:3 Portrait)", configuration: makeConfiguration(logicalWidth: 1536, logicalHeight: 2048, scale: .standard1x)),
        DisplayResolutionPreset(title: "1488 x 2266 @1x (iPad mini Portrait, 326 ppi)", configuration: makeConfiguration(logicalWidth: 1488, logicalHeight: 2266, scale: .standard1x, pixelsPerInch: 326)),
        DisplayResolutionPreset(title: "1668 x 2420 @1x (264 ppi Portrait)", configuration: makeConfiguration(logicalWidth: 1668, logicalHeight: 2420, scale: .standard1x, pixelsPerInch: 264)),
        DisplayResolutionPreset(title: "744 x 1133 @2x (1488 x 2266, iPad mini Portrait)", configuration: makeConfiguration(logicalWidth: 744, logicalHeight: 1133, scale: .retina2x, pixelsPerInch: 326)),
        DisplayResolutionPreset(title: "834 x 1194 @2x (iPad Pro 11\" Portrait)", configuration: makeConfiguration(logicalWidth: 834, logicalHeight: 1194, scale: .retina2x)),
        DisplayResolutionPreset(title: "834 x 1210 @2x (1668 x 2420, 264 ppi)", configuration: makeConfiguration(logicalWidth: 834, logicalHeight: 1210, scale: .retina2x, pixelsPerInch: 264)),
        DisplayResolutionPreset(title: "1024 x 1366 @2x (iPad Pro 12.9\" Portrait)", configuration: makeConfiguration(logicalWidth: 1024, logicalHeight: 1366, scale: .retina2x)),
        DisplayResolutionPreset(title: "1032 x 1376 @2x (2064 x 2752, iPad Pro 13\" Portrait)", configuration: makeConfiguration(logicalWidth: 1032, logicalHeight: 1376, scale: .retina2x, pixelsPerInch: 264)),
        DisplayResolutionPreset(title: "2064 x 2752 @1x (iPad Pro 13\" Portrait)", configuration: makeConfiguration(logicalWidth: 2064, logicalHeight: 2752, scale: .standard1x, pixelsPerInch: 264))
    ]

    private static func makeConfiguration(logicalWidth: Int, logicalHeight: Int, scale: XDisplayScale, pixelsPerInch: Double = 110.0) -> XDisplayDisplayConfiguration {
        do {
            return try XDisplayDisplayConfiguration(
                logicalSize: XDisplaySize(width: logicalWidth, height: logicalHeight),
                scale: scale,
                pixelsPerInch: pixelsPerInch
            )
        } catch {
            preconditionFailure("Invalid bundled display configuration: \(error)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure as a background/accessory app (no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        #if canImport(Sparkle)
        #if !DEBUG
        // Initialize Sparkle Updater
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
        #endif

        requestAccessibilityPermissionIfNeeded()
        setupMenuBar()

        if ProcessInfo.processInfo.environment["XDISPLAY_AUTO_START"] == "1" {
            print("[*] Test Mode: Auto-starting virtual display...")
            startDisplay()
        } else {
            print("[*] Auto-start disabled. Use the menu to start virtual display.")
        }
    }

    private func requestAccessibilityPermissionIfNeeded() {
        // Use literal string instead of kAXTrustedCheckOptionPrompt to avoid concurrency warnings
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            print("[+] Accessibility: trusted – CGEvent.post will work.")
        } else {
            print("[!] Accessibility: NOT trusted. iPad input events will be silently dropped.")
            print("[!] Grant access in: System Settings > Privacy & Security > Accessibility")
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        // Set menu bar image using SF Symbols with template coloring for dark/light mode compatibility
        if let image = NSImage(systemSymbolName: "display.and.ipad", accessibilityDescription: "X-Display Menu") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        } else {
            // Fallback to text title if SF Symbol loading fails
            button.title = "🖥️"
        }

        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()

        // 1. Status Indicator
        let statusTitle = isDisplayActive ? "Status: Active Streaming" : "Status: Idle"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 2. Start / Stop Action
        if isDisplayActive {
            let stopItem = NSMenuItem(title: "Stop Virtual Display", action: #selector(stopDisplay), keyEquivalent: "s")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(title: "Start Virtual Display", action: #selector(startDisplay), keyEquivalent: "g")
            startItem.target = self
            menu.addItem(startItem)
        }

        // 3. Resolutions Submenu
        let resItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        let resMenu = NSMenu()

        for (index, preset) in Self.resolutionPresets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(selectResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = index
            item.state = (preset.configuration == selectedConfiguration) ? .on : .off
            resMenu.addItem(item)
        }

        resItem.submenu = resMenu
        menu.addItem(resItem)

        let codecItem = NSMenuItem(title: "Codec", action: nil, keyEquivalent: "")
        let codecMenu = NSMenu()
        for codec in [XDisplayVideoCodec.h264, .hevc] {
            let item = NSMenuItem(title: codec.displayName, action: #selector(selectCodec(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = codec.rawValue
            item.state = (codec == selectedCodec) ? .on : .off
            codecMenu.addItem(item)
        }
        codecItem.submenu = codecMenu
        menu.addItem(codecItem)

        menu.addItem(NSMenuItem.separator())

        // 4. Quit Action
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    private func performStartDisplay() async throws {
        let configuration = selectedConfiguration
        let codec = selectedCodec
        let logicalSize = configuration.logicalSize
        let pixelSize = configuration.pixelSize
        print("[*] Creating virtual display logical=\(logicalSize.width)x\(logicalSize.height), pixel=\(pixelSize.width)x\(pixelSize.height), scale=\(configuration.scale.multiplier)x, ppi=\(configuration.pixelsPerInch), codec=\(codec.displayName)...")
        try helper.createVirtualDisplay(
            withLogicalWidth: UInt32(logicalSize.width),
            logicalHeight: UInt32(logicalSize.height),
            pixelWidth: UInt32(pixelSize.width),
            pixelHeight: UInt32(pixelSize.height),
            hiDPI: configuration.scale.isHiDPI,
            pixelsPerInch: configuration.pixelsPerInch
        )

        isDisplayActive = true
        updateMenu()

        print("[*] Waiting 1.5s for WindowServer display registration...")
        try await Task.sleep(nanoseconds: 1_500_000_000)

        print("[*] Launching capture & streaming pipeline...")
        let createdDisplayID = helper.currentDisplayID()
        let preferredDisplayID = createdDisplayID == kCGNullDirectDisplay ? nil : createdDisplayID
        try await captureManager.startCaptureOfVirtualDisplay(
            configuration: configuration,
            codec: codec,
            virtualDisplayID: preferredDisplayID
        )

        print("[+] X-Display Streaming is now active.")
    }

    private func performStopDisplay(keepServer: Bool = false) async {
        print("[*] Stopping screen capture stream...")
        await captureManager.stopCapture(keepServer: keepServer)

        print("[*] Destroying virtual display and releasing ports...")
        helper.destroyVirtualDisplay()
        print("[+] Streaming stopped & resources cleaned up.")
    }

    @objc private func startDisplay() {
        guard !isDisplayActive else { return }

        Task {
            do {
                try await performStartDisplay()
            } catch {
                print("[-] Error while starting display: \(error.localizedDescription)")
                await performStopDisplay()
                isDisplayActive = false
                updateMenu()
            }
        }
    }

    @objc private func stopDisplay() {
        guard isDisplayActive else { return }
        isDisplayActive = false
        updateMenu()

        Task {
            await performStopDisplay()
        }
    }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              Self.resolutionPresets.indices.contains(index) else {
            return
        }
        selectedConfiguration = Self.resolutionPresets[index].configuration

        let logicalSize = selectedConfiguration.logicalSize
        let pixelSize = selectedConfiguration.pixelSize
        print("[*] Resolution changed to logical=\(logicalSize.width)x\(logicalSize.height), pixel=\(pixelSize.width)x\(pixelSize.height), scale=\(selectedConfiguration.scale.multiplier)x, ppi=\(selectedConfiguration.pixelsPerInch)")
        updateMenu()

        if isDisplayActive {
            Task {
                await performStopDisplay(keepServer: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
                do {
                    try await performStartDisplay()
                } catch {
                    print("[-] Failed to restart display after resolution change: \(error.localizedDescription)")
                    await performStopDisplay()
                    isDisplayActive = false
                    updateMenu()
                }
            }
        }
    }

    @objc private func selectCodec(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? UInt8,
              let codec = XDisplayVideoCodec(rawValue: rawValue) else {
            return
        }

        selectedCodec = codec
        print("[*] Codec changed to: \(codec.displayName)")
        updateMenu()

        if isDisplayActive {
            Task {
                await performStopDisplay(keepServer: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
                do {
                    try await performStartDisplay()
                } catch {
                    print("[-] Failed to restart display after codec change: \(error.localizedDescription)")
                    await performStopDisplay()
                    isDisplayActive = false
                    updateMenu()
                }
            }
        }
    }

    @objc private func quitApp() {
        stopDisplay()
        NSApp.terminate(nil)
    }
}

@main
struct X_display {
    @MainActor
    private static var strongDelegate: XDisplayAppManager?

    @MainActor
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        print("[*] Initializing macOS MenuBar Application...")
        let app = NSApplication.shared
        let delegate = XDisplayAppManager()
        strongDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

private extension XDisplayVideoCodec {
    var displayName: String {
        switch self {
        case .h264:
            return "H.264"
        case .hevc:
            return "HEVC"
        }
    }
}
#endif
