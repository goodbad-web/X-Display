#if os(macOS)
import Foundation
import AppKit
import ScreenCaptureKit
#if canImport(CVirtualDisplay)
import CVirtualDisplay
#endif
import CoreMedia

final class ScreenCaptureManager: NSObject, @unchecked Sendable, SCStreamOutput, VideoEncoderDelegate, StreamServerDelegate {
    private var stream: SCStream?
    private var frameCount = 0
    private var lastFrameTime = Date()
    private let encoder = VideoEncoder()
    private let server = StreamServer()
    private var displayID: CGDirectDisplayID?
    
    func startCaptureOfVirtualDisplay(width: Int, height: Int) async {
        do {
            print("[*] Starting StreamServer...")
            server.delegate = self
            try server.start(port: 12345)
            
            print("[*] Initializing VideoEncoder...")
            encoder.delegate = self
            encoder.initialize(width: width, height: height)
            
            print("[*] Retrieving shareable content...")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            
            // Find the virtual display by width and height resolution
            guard let targetDisplay = content.displays.first(where: { Int($0.width) == width && Int($0.height) == height }) else {
                print("[-] Target virtual display not found. Please ensure it is created.")
                server.stop()
                return
            }
            
            self.displayID = targetDisplay.displayID
            print("[+] Target display found! ID: \(targetDisplay.displayID) Resolution: \(Int(targetDisplay.width))x\(Int(targetDisplay.height))")
            
            // Create a content filter targeting the virtual display
            let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
            
            // Configure zero-latency stream settings
            let config = SCStreamConfiguration()
            config.width = width
            config.height = height
            config.pixelFormat = kCVPixelFormatType_32BGRA // GPU-friendly format
            config.queueDepth = 3 // Keep queue depth shallow to prevent latency accumulation
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // Target 60 FPS
            config.showsCursor = true
            
            print("[*] Initializing SCStream...")
            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            
            // Set output callback on a dedicated user-interactive serial queue
            let captureQueue = DispatchQueue(label: "com.xdisplay.capture-queue", qos: .userInteractive)
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            
            print("[*] Starting SCStream capture...")
            try await stream?.startCapture()
            print("[+] SCStream started successfully! Capturing frames...")
            lastFrameTime = Date()
            
        } catch {
            print("[-] SCStream start failed: \(error.localizedDescription)")
            server.stop()
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
        
        frameCount += 1
        let now = Date()
        let interval = now.timeIntervalSince(lastFrameTime)
        
        // Log status every 60 frames (approx. 1 second at 60fps)
        if frameCount % 60 == 0 {
            let fps = 60.0 / interval
            print(String(format: "[+] Cap Frame #%04d | Latency tracking OK | FPS: %.1f", frameCount, fps))
            lastFrameTime = now
        }
        
        // Retrieve the pixel buffer and pass it to VideoToolbox encoder
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            encoder.encode(pixelBuffer: pixelBuffer, presentationTime: pts)
        }
    }
    
    // VideoEncoderDelegate callback
    func videoEncoder(_ encoder: VideoEncoder, didEncodeNALUnit data: Data, isKeyFrame: Bool) {
        // Broadcast the H.264 raw NAL unit to all connected clients
        server.broadcast(data: data)
    }
    
    // StreamServerDelegate callback
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
}

@MainActor
class XDisplayAppManager: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let helper = CVirtualDisplayHelper.shared()
    private let captureManager = ScreenCaptureManager()
    
    private var isDisplayActive = false
    private var selectedWidth = 1920
    private var selectedHeight = 1080
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure as a background/accessory app (no Dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        setupMenuBar()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        
        // Set menu bar image using SF Symbols
        button.image = NSImage(systemSymbolName: "display.and.ipad", accessibilityDescription: "X-Display Menu")
        button.imagePosition = .imageLeft
        
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
            (1920, 1080, "1920 x 1080 (16:9)"),
            (2048, 1536, "2048 x 1536 (4:3)"),
            (2732, 2048, "2732 x 2048 (iPad Pro)")
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
        isDisplayActive = true
        updateMenu()
        
        Task {
            do {
                print("[*] Creating virtual display (\(selectedWidth)x\(selectedHeight))...")
                try helper.createVirtualDisplay(withWidth: UInt32(selectedWidth), height: UInt32(selectedHeight))
                
                print("[*] Waiting 1.5s for WindowServer display registration...")
                try await Task.sleep(nanoseconds: 1_500_000_000)
                
                print("[*] Launching capture & streaming pipeline...")
                await captureManager.startCaptureOfVirtualDisplay(width: selectedWidth, height: selectedHeight)
                
                print("[+] X-Display Streaming is now active.")
            } catch {
                print("[-] Error while starting display: \(error.localizedDescription)")
                stopDisplay()
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
    static func main() {
        print("[*] Initializing macOS MenuBar Application...")
        let app = NSApplication.shared
        let delegate = XDisplayAppManager()
        app.delegate = delegate
        app.run()
    }
}
#endif

