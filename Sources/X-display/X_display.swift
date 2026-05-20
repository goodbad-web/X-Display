#if os(macOS)
import Foundation
import ScreenCaptureKit
import CVirtualDisplay
import CoreMedia

class ScreenCaptureManager: NSObject, SCStreamOutput, VideoEncoderDelegate, StreamServerDelegate {
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

@main
struct X_display {
    static func main() async {
        print("==================================================")
        print("  macOS ScreenCaptureKit Zero-Latency Capture PoC ")
        print("==================================================")
        
        let helper = CVirtualDisplayHelper.shared()
        let captureManager = ScreenCaptureManager()
        
        let displayWidth = 1920
        let displayHeight = 1080
        
        do {
            print("[*] Step 1: Creating virtual display (\(displayWidth)x\(displayHeight))...")
            try helper.createVirtualDisplay(withWidth: UInt32(displayWidth), height: UInt32(displayHeight))
            print("[+] Virtual display created successfully!")
            
            // Sleep briefly to let WindowServer register the new display
            print("[*] Waiting 1.5s for OS to register the display...")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            
            print("[*] Step 2: Starting ScreenCaptureKit stream...")
            await captureManager.startCaptureOfVirtualDisplay(width: displayWidth, height: displayHeight)
            
            print("==================================================")
            print("[!] Verification status: ACTIVE")
            print("[!] Please check System Settings -> Displays")
            print("[*] Press [ENTER] key to stop capturing, destroy display and exit...")
            print("==================================================")
            
            _ = readLine()
            
            print("[*] Stopping screen capture stream...")
            await captureManager.stopCapture()
            
        } catch {
            print("[-] Error occurred: \(error.localizedDescription)")
        }
        
        print("[*] Destroying virtual display and releasing resources...")
        helper.destroyVirtualDisplay()
        print("[+] Terminated successfully.")
    }
}
#endif

