import SwiftUI
import Network
import CoreVideo
import XDisplayShared

@MainActor
final class FrameHolder {
    typealias Renderer = @MainActor (CVPixelBuffer?) -> Void

    private let lock = NSLock()
    private var renderer: Renderer?

    func setRenderer(_ renderer: Renderer?) {
        lock.lock()
        self.renderer = renderer
        lock.unlock()
    }

    func display(_ pixelBuffer: CVPixelBuffer?) {
        lock.lock()
        let renderer = self.renderer
        lock.unlock()

        DispatchQueue.main.async {
            renderer?(pixelBuffer)
        }
    }
}

@MainActor
class AppViewModel: ObservableObject, StreamClientDelegate, VideoDecoderDelegate {
    @Published var connectionStatus: String = "Disconnected"
    @Published var isConnected = false {
        didSet {
            if isConnected {
                self.startScreenSaverTimer()
            } else {
                self.stopScreenSaverTimer()
            }
        }
    }
    @Published var isPairingRequired = false
    @Published var enteredPIN: String = ""
    @Published var hostGeneratedPIN: String? = nil
    @Published var frameSize: CGSize = .init(width: 1920, height: 1080)
    @Published var isTransitioning: Bool = false
    @Published var isClientPortrait: Bool = false
    @Published var isScreenSaverActive: Bool = false

    private var lastActivityTime: Date = Date()
    private var originalBrightness: CGFloat = 0.5
    private var screenSaverTimer: Timer?
    let frameHolder = FrameHolder()
    @Published var discoveredDevices: [DiscoveredDevice] = [] {
        didSet {
            checkAndPerformAutoSwitch()
        }
    }

    private let streamClient = StreamClient()
    private let videoDecoder = VideoDecoder()
    private let deviceBrowser = DeviceBrowser()

    private var activeEndpoint: NWEndpoint?
    private var activeConnectionType: ConnectionType?
    private var lastWirelessEndpoint: NWEndpoint?
    private var isAutoSwitching = false

    init() {
        streamClient.delegate = self
        videoDecoder.delegate = self

        // Bind Bonjour browser results
        deviceBrowser.$discoveredDevices
            .assign(to: &$discoveredDevices)
    }

    func startDiscovery() {
        deviceBrowser.startBrowsing()
        streamClient.startListening(port: 0)
    }

    func connect(endpoint: NWEndpoint, type: ConnectionType) {
        if type == .wired {
            deviceBrowser.stopBrowsing()
        }
        connectionStatus = "Connecting..."
        videoDecoder.reset()
        
        self.activeEndpoint = endpoint
        self.activeConnectionType = type
        if type == .wireless {
            self.lastWirelessEndpoint = endpoint
        }
        
        streamClient.connect(endpoint: endpoint, type: type)
    }

    func connect(host: String, port: UInt16) {
        deviceBrowser.stopBrowsing()
        connectionStatus = "Connecting..."
        videoDecoder.reset()
        
        self.activeEndpoint = .hostPort(host: .init(host), port: .init(rawValue: port)!)
        self.activeConnectionType = .wireless
        self.lastWirelessEndpoint = self.activeEndpoint
        
        streamClient.connect(host: host, port: port)
    }

    func disconnect() {
        print("[*] AppViewModel.disconnect() called from stack:\n\(Thread.callStackSymbols.prefix(5).joined(separator: "\n"))")
        streamClient.disconnect(reason: "AppViewModel request")
        videoDecoder.reset()
        isConnected = false
        isPairingRequired = false
        enteredPIN = ""
        hostGeneratedPIN = nil
        connectionStatus = "Disconnected"
        frameHolder.display(nil)
        
        self.activeEndpoint = nil
        self.activeConnectionType = nil
        self.isAutoSwitching = false
        
        deviceBrowser.startBrowsing()
    }

    func submitPIN() {
        streamClient.submitPIN(enteredPIN)
        enteredPIN = ""
    }

    #if os(iOS)
    func sendTouchEvent(_ event: TouchEvent) {
        registerActivity()
        streamClient.sendInputEvent(phase: event.phase, x: event.x, y: event.y, pressure: event.pressure)
    }
    #endif

    func sendScrollEvent(deltaX: Float, deltaY: Float, x: Float, y: Float) {
        registerActivity()
        streamClient.sendScrollEvent(deltaX: deltaX, deltaY: deltaY, x: x, y: y)
    }

    func sendRightClickEvent(x: Float, y: Float) {
        registerActivity()
        streamClient.sendRightClickEvent(x: x, y: y)
    }

    func sendPencilEvent(_ event: XDisplayPencilEvent) {
        registerActivity()
        streamClient.sendPencilEvent(event)
    }

    func sendPencilInteractionEvent(_ event: XDisplayPencilInteractionEvent) {
        registerActivity()
        streamClient.sendPencilInteractionEvent(event)
    }

    func sendClientInfo() {
        let codecStr = UserDefaults.standard.string(forKey: "selectedCodec") ?? "HEVC"
        let codec: XDisplayVideoCodec = (codecStr == "H.264") ? .h264 : .hevc
        let maxFps = UserDefaults.standard.integer(forKey: "maxFrameRate")
        let fps = (maxFps == 30) ? UInt8(30) : UInt8(60)
        
        streamClient.sendClientInfo(
            isPortrait: self.isClientPortrait,
            preferredCodec: codec,
            maxFrameRate: fps
        )
    }

    func updateOrientation(isPortrait: Bool) {
        if self.isClientPortrait != isPortrait {
            self.isClientPortrait = isPortrait
            self.isTransitioning = true
            sendClientInfo()
        }
    }

    private func checkAndPerformAutoSwitch() {
        guard isConnected, activeConnectionType == .wireless else { return }
        guard let currentEndpoint = activeEndpoint else { return }
        
        let currentName: String
        if case let .service(name, _, _, _) = currentEndpoint {
            currentName = name
        } else {
            return
        }
        
        if let wiredDevice = discoveredDevices.first(where: { $0.name == currentName && $0.type == .wired }) {
            print("[+] Auto-Switch: Wired connection detected for \(currentName). Migrating from Wi-Fi...")
            
            self.isAutoSwitching = true
            self.connectionStatus = "Switching to Wired..."
            
            streamClient.disconnect(reason: "Auto-switching to wired connection")
            videoDecoder.reset()
            isConnected = false
            isPairingRequired = false
            enteredPIN = ""
            
            self.connect(endpoint: wiredDevice.endpoint, type: .wired)
        }
    }

    // StreamClientDelegate
    func streamClient(_ client: StreamClient, didReceiveVideoFrame data: Data, codec: XDisplayVideoCodec) {
        DispatchQueue.main.async {
            self.registerActivity()
        }
        videoDecoder.decode(codec: codec, data: data)
    }

    func streamClient(_ client: StreamClient, connectionStateDidChange state: NWConnection.State) {
        DispatchQueue.main.async {
            switch state {
            case .setup:
                self.connectionStatus = "Connecting..."
            case .preparing:
                self.connectionStatus = "Connecting..."
            case .waiting(let error):
                self.connectionStatus = "Waiting: \(error.localizedDescription)"
            case .ready:
                // TCP接続確立のみ。isConnected はペアリング完了後に設定する
                self.connectionStatus = "Authenticating..."
            case .failed(let error):
                if self.activeConnectionType == .wired, let fallbackEndpoint = self.lastWirelessEndpoint {
                    print("[-] Wired connection lost. Falling back to Wireless...")
                    self.connectionStatus = "Fallback to Wireless..."
                    self.isConnected = false
                    self.isPairingRequired = false
                    self.connect(endpoint: fallbackEndpoint, type: .wireless)
                } else {
                    self.connectionStatus = "Failed: \(error.localizedDescription)"
                    self.isConnected = false
                    self.isPairingRequired = false
                    self.deviceBrowser.startBrowsing()
                }
            case .cancelled:
                if self.isAutoSwitching {
                    self.isAutoSwitching = false
                    break
                }
                self.connectionStatus = "Disconnected"
                self.isConnected = false
                self.isPairingRequired = false
                self.deviceBrowser.startBrowsing()
            @unknown default:
                break
            }
        }
    }

    func streamClient(_ client: StreamClient, didRequestPINWithSalt salt: Data) {
        DispatchQueue.main.async {
            self.connectionStatus = "PIN required"
            self.isPairingRequired = true
        }
    }
    
    func streamClient(_ client: StreamClient, didAcceptConnectionWithPIN pin: String) {
        DispatchQueue.main.async {
            self.hostGeneratedPIN = pin
            self.connectionStatus = "Mac is connecting..."
        }
    }

    func streamClient(_ client: StreamClient, didFinishPairingWithResult success: Bool) {
        DispatchQueue.main.async {
            self.isPairingRequired = false
            self.hostGeneratedPIN = nil
            self.connectionStatus = success ? "Connected" : "Pairing failed"
            self.isConnected = success
            if success {
                self.sendClientInfo()
            } else {
                self.disconnect()
            }
        }
    }

    // VideoDecoderDelegate
    func videoDecoder(_ decoder: VideoDecoder, didDecodeImageBuffer pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let newSize = CGSize(width: width, height: height)
        
        DispatchQueue.main.async {
            if self.frameSize != newSize {
                self.frameSize = newSize
            }
            
            // If the incoming frame aspect ratio matches the client's current portrait state, we finish the transition
            let frameIsPortrait = height > width
            if self.isTransitioning && frameIsPortrait == self.isClientPortrait {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.isTransitioning = false
                }
            }
        }
        
        frameHolder.display(pixelBuffer)
    }

    // Screen Saver (Power Saving) Logic
    private func startScreenSaverTimer() {
        DispatchQueue.main.async {
            self.screenSaverTimer?.invalidate()
            self.lastActivityTime = Date()
            self.screenSaverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkScreenSaverTimeout()
                }
            }
        }
    }

    private func stopScreenSaverTimer() {
        DispatchQueue.main.async {
            self.screenSaverTimer?.invalidate()
            self.screenSaverTimer = nil
            self.deactivateScreenSaver()
        }
    }

    private func checkScreenSaverTimeout() {
        let enable = UserDefaults.standard.bool(forKey: "enableScreenSaver")
        guard enable else { return }

        let timeoutMinutes = UserDefaults.standard.integer(forKey: "screenSaverTimeoutMinutes")
        // Default to 5 minutes if not configured or 0
        let timeoutSeconds = Double(timeoutMinutes == 0 ? 300 : timeoutMinutes * 60)

        let elapsed = Date().timeIntervalSince(lastActivityTime)
        if elapsed >= timeoutSeconds {
            if !isScreenSaverActive {
                activateScreenSaver()
            }
        }
    }

    private func activateScreenSaver() {
        guard !isScreenSaverActive else { return }
        print("[+] Screen saver activated. Saving power...")

        DispatchQueue.main.async {
            #if os(iOS)
            self.originalBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 0.0
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            withAnimation(.easeInOut(duration: 0.5)) {
                self.isScreenSaverActive = true
            }
        }
    }

    private func deactivateScreenSaver() {
        guard isScreenSaverActive else { return }
        print("[-] Screen saver deactivated.")

        DispatchQueue.main.async {
            #if os(iOS)
            UIScreen.main.brightness = self.originalBrightness
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
            withAnimation(.easeInOut(duration: 0.3)) {
                self.isScreenSaverActive = false
            }
        }
    }

    func registerActivity() {
        lastActivityTime = Date()
        if isScreenSaverActive {
            deactivateScreenSaver()
        }
    }

    deinit {
        let browser = deviceBrowser
        Task { @MainActor in
            browser.stopBrowsing()
        }
    }
}
