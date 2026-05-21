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

final class ScreenCaptureManager: NSObject, @unchecked Sendable, SCStreamOutput, VideoEncoderDelegate, StreamServerDelegate {
    private var stream: SCStream?
    private let encoder = VideoEncoder()
    private let server = StreamServer()
    private var displayID: CGDirectDisplayID?
    private var didRequestScreenCaptureAccess = false

    // Keep only the newest pending frame so latency does not grow under load.
    private let encodeQueue = DispatchQueue(label: "com.xdisplay.encode-queue", qos: .userInteractive)
    private var isEncodeWorkerRunning = false
    private var pendingFrame: PendingVideoFrame?
    private let encodingLock = NSLock()
    private var capturedFrameCount = 0
    private var submittedFrameCount = 0
    private var replacedFrameCount = 0
    private var lastStatsTime = Date()
    private var lastCapturedFrameCount = 0
    private var lastSubmittedFrameCount = 0
    private var lastReplacedFrameCount = 0

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

    func startCaptureOfVirtualDisplay(width: Int, height: Int) async throws {
        do {
            await requestScreenCaptureAccessIfNeeded()

            print("[*] Starting StreamServer...")
            server.delegate = self
            try server.start(port: 12345)

            print("[*] Initializing VideoEncoder...")
            encoder.delegate = self
            encoder.initialize(width: width, height: height)

            print("[*] Retrieving shareable content...")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // Find the virtual display by width and height resolution.
            guard let targetDisplay = content.displays.first(where: { Int($0.width) == width && Int($0.height) == height }) else {
                print("[-] Target virtual display not found. Please ensure it is created.")
                server.stop()
                throw NSError(domain: "ScreenCaptureManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Target virtual display not found."])
            }

            self.displayID = targetDisplay.displayID
            print("[+] Target display found! ID: \(targetDisplay.displayID) Resolution: \(Int(targetDisplay.width))x\(Int(targetDisplay.height))")

            // Create a content filter targeting the virtual display.
            let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])

            // Configure zero-latency stream settings.
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.pixelFormat = kCVPixelFormatType_32BGRA // GPU-friendly format
            config.queueDepth = 1
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.showsCursor = true
            config.capturesAudio = false

            print("[*] Initializing SCStream...")
            stream = SCStream(filter: filter, configuration: config, delegate: nil)

            // Set output callback on a dedicated user-interactive serial queue.
            let captureQueue = DispatchQueue(label: "com.xdisplay.capture-queue", qos: .userInteractive)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

            print("[*] Starting SCStream capture...")
            try await stream?.startCapture()
            print("[+] SCStream started successfully! Capturing frames...")
            resetCaptureStats()
        } catch {
            print("[-] SCStream start failed: \(error.localizedDescription)")
            server.stop()
            throw error
        }
    }

    func stopCapture() async {
        guard let stream = stream else { return }
        do {
            try await stream.stopCapture()
            print("[+] SCStream stopped.")
        } catch {
            print("[-] SCStream stop failed: \(error.localizedDescription)")
        }
        self.stream = nil
        server.stop()
    }

    // SCStreamOutput callback
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        guard server.hasActivePairedConnections else {
            return
        }

        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            enqueueLatestFrame(
                PendingVideoFrame(
                    pixelBuffer: SendablePixelBuffer(buffer: pixelBuffer),
                    presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                )
            )
        }

        logCaptureStatsIfNeeded()
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
    func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnit data: Data, isKeyFrame: Bool) {
        // Broadcast the H.264 raw NAL unit to all connected clients
        server.broadcast(data: data)
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
        encoder.requestKeyFrame()
    }

    func streamServer(_ server: StreamServer, didReceiveInputEvent phase: UInt8, x: Float, y: Float, pressure: Float) {
        guard let displayID = self.displayID else { return }

        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 && bounds.height > 0 else { return }

        // Map normalized 0.0 ~ 1.0 coordinates to the target virtual display bounds
        let absoluteX = bounds.origin.x + CGFloat(x) * bounds.size.width
        let absoluteY = bounds.origin.y + CGFloat(y) * bounds.size.height
        let point = CGPoint(x: absoluteX, y: absoluteY)

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

    func streamServer(_ server: StreamServer, didReceiveScrollEvent deltaX: Float, deltaY: Float) {
        // Natural scrolling feeling: scale scroll translations and post wheel events.
        // CGEvent scroll delta has vertical in wheel1, horizontal in wheel2.
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
        
        event.post(tap: CGEventTapLocation.cghidEventTap)
    }


    func streamServer(_ server: StreamServer, didReceiveRightClickEvent x: Float, y: Float) {
        guard let displayID = self.displayID else { return }

        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let absoluteX = bounds.origin.x + CGFloat(x) * bounds.size.width
        let absoluteY = bounds.origin.y + CGFloat(y) * bounds.size.height
        let point = CGPoint(x: absoluteX, y: absoluteY)
        
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
        guard let displayID = self.displayID else { return }

        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 && bounds.height > 0 else { return }

        let absoluteX = bounds.origin.x + CGFloat(event.x) * bounds.size.width
        let absoluteY = bounds.origin.y + CGFloat(event.y) * bounds.size.height
        let point = CGPoint(x: absoluteX, y: absoluteY)

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
    private var statusItem: NSStatusItem?
    private let helper = CVirtualDisplayHelper.shared()
    private let captureManager = ScreenCaptureManager()

    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private var isDisplayActive = false
    private var selectedWidth = 1920
    private var selectedHeight = 1080

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure as a background/accessory app (no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        #if canImport(Sparkle)
        #if !DEBUG
        // Initialize Sparkle Updater
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
        #endif

        setupMenuBar()

        if ProcessInfo.processInfo.environment["XDISPLAY_AUTO_START"] == "1" {
            print("[*] Test Mode: Auto-starting virtual display...")
            startDisplay()
        } else {
            print("[*] Auto-start disabled. Use the menu to start virtual display.")
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

        let resolutions = [
            // --- Landscape ---
            (1920, 1080, "1920 x 1080 (16:9)"),
            (2048, 1536, "2048 x 1536 (4:3)"),
            (2266, 1488, "2266 x 1488 (iPad mini 6)"),
            (2388, 1668, "2388 x 1668 (iPad Pro 11\")"),
            (2732, 2048, "2732 x 2048 (iPad Pro 12.9\")"),
            
            // --- Portrait ---
            (1080, 1920, "1080 x 1920 (16:9 Portrait)"),
            (1536, 2048, "1536 x 2048 (4:3 Portrait)"),
            (1488, 2266, "1488 x 2266 (iPad mini 6 Portrait)"),
            (1668, 2388, "1668 x 2388 (iPad Pro 11\" Portrait)"),
            (2048, 2732, "2048 x 2732 (iPad Pro 12.9\" Portrait)")
        ]

        for (w, h, title) in resolutions {
            let item = NSMenuItem(title: title, action: #selector(selectResolution(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [w, h]
            item.state = (w == selectedWidth && h == selectedHeight) ? .on : .off
            resMenu.addItem(item)
        }

        resItem.submenu = resMenu
        menu.addItem(resItem)

        menu.addItem(NSMenuItem.separator())

        // 4. Quit Action
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func startDisplay() {
        guard !isDisplayActive else { return }

        Task {
            do {
                print("[*] Creating virtual display (\(selectedWidth)x\(selectedHeight))...")
                try helper.createVirtualDisplay(withWidth: UInt32(selectedWidth), height: UInt32(selectedHeight))

                isDisplayActive = true
                updateMenu()

                print("[*] Waiting 1.5s for WindowServer display registration...")
                try await Task.sleep(nanoseconds: 1_500_000_000)

                print("[*] Launching capture & streaming pipeline...")
                try await captureManager.startCaptureOfVirtualDisplay(width: selectedWidth, height: selectedHeight)

                print("[+] X-Display Streaming is now active.")
            } catch {
                print("[-] Error while starting display: \(error.localizedDescription)")
                await captureManager.stopCapture()
                helper.destroyVirtualDisplay()
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
            print("[*] Stopping screen capture stream...")
            await captureManager.stopCapture()

            print("[*] Destroying virtual display and releasing ports...")
            helper.destroyVirtualDisplay()
            print("[+] Streaming stopped & resources cleaned up.")
        }
    }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? [Int], size.count == 2 else { return }
        selectedWidth = size[0]
        selectedHeight = size[1]

        print("[*] Resolution changed to: \(selectedWidth)x\(selectedHeight)")
        updateMenu()

        if isDisplayActive {
            stopDisplay()
            // Grace period to let the old virtual display tear down cleanly
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startDisplay()
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
#endif
