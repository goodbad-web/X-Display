import SwiftUI
import Network
import CoreVideo
import XDisplayShared

@main
struct XDisplayClientApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

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

class AppViewModel: ObservableObject, StreamClientDelegate, VideoDecoderDelegate {
    @Published var connectionStatus: String = "Disconnected"
    @Published var isConnected = false
    @Published var isPairingRequired = false
    @Published var enteredPIN: String = ""
    @Published var frameSize: CGSize = .init(width: 1920, height: 1080)
    @Published var isTransitioning: Bool = false
    @Published var isClientPortrait: Bool = false
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
    private var lastSuccessfulPIN: String?
    private var isAutoSwitching = false

    init() {
        streamClient.delegate = self
        videoDecoder.delegate = self

        // Bind Bonjour browser results
        deviceBrowser.$discoveredDevices
            .assign(to: &$discoveredDevices)

        deviceBrowser.startBrowsing()
    }

    func connect(endpoint: NWEndpoint, type: ConnectionType) {
        deviceBrowser.stopBrowsing()
        connectionStatus = "Connecting..."
        videoDecoder.reset()
        
        self.activeEndpoint = endpoint
        self.activeConnectionType = type
        if type == .wireless {
            self.lastWirelessEndpoint = endpoint
        }
        
        streamClient.connect(endpoint: endpoint)
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
        connectionStatus = "Disconnected"
        frameHolder.display(nil)
        
        self.activeEndpoint = nil
        self.activeConnectionType = nil
        self.isAutoSwitching = false
        
        deviceBrowser.startBrowsing()
    }

    func submitPIN() {
        self.lastSuccessfulPIN = enteredPIN
        streamClient.submitPIN(enteredPIN)
        enteredPIN = ""
    }

    func sendTouchEvent(_ event: TouchEvent) {
        streamClient.sendInputEvent(phase: event.phase, x: event.x, y: event.y, pressure: event.pressure)
    }

    func sendScrollEvent(deltaX: Float, deltaY: Float, x: Float, y: Float) {
        streamClient.sendScrollEvent(deltaX: deltaX, deltaY: deltaY, x: x, y: y)
    }

    func sendRightClickEvent(x: Float, y: Float) {
        streamClient.sendRightClickEvent(x: x, y: y)
    }

    func sendPencilEvent(_ event: XDisplayPencilEvent) {
        streamClient.sendPencilEvent(event)
    }

    func sendPencilInteractionEvent(_ event: XDisplayPencilInteractionEvent) {
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
            if let lastPIN = self.lastSuccessfulPIN {
                print("[+] Auto-Pairing using cached PIN...")
                self.connectionStatus = "Auto-Authenticating..."
                self.streamClient.submitPIN(lastPIN)
            } else {
                self.connectionStatus = "PIN required"
                self.isPairingRequired = true
            }
        }
    }

    func streamClient(_ client: StreamClient, didFinishPairingWithResult success: Bool) {
        DispatchQueue.main.async {
            self.isPairingRequired = false
            self.connectionStatus = success ? "Connected" : "Pairing failed"
            self.isConnected = success
            if success {
                self.sendClientInfo()
            } else {
                self.lastSuccessfulPIN = nil
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

    deinit {
        deviceBrowser.stopBrowsing()
    }
}

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var hostAddress: String = ""
    @State private var hostPort: String = "12345"
    @State private var showManualConnection = false

    @State private var isIdle = false
    @State private var idleTimerTask: Task<Void, Never>? = nil
    @State private var showSettings = false

    // Sync settings with UserDefaults
    @AppStorage("enableApplePencil") private var enableApplePencil = true
    @AppStorage("idleTimeoutSeconds") private var idleTimeoutSeconds = 5
    @AppStorage("selectedCodec") private var selectedCodec = "HEVC"
    @AppStorage("maxFrameRate") private var maxFrameRate = 60

    private func resetIdleTimer() {
        idleTimerTask?.cancel()
        if isIdle {
            withAnimation(.easeInOut(duration: 0.3)) {
                isIdle = false
            }
        }
        idleTimerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(idleTimeoutSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                isIdle = true
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let isPortrait = geometry.size.height > geometry.size.width
            
            ZStack {
                if viewModel.isConnected {
                    // Zero-Latency Video streaming viewport with touch overlay
                    ZStack {
                        StreamViewport(frameHolder: viewModel.frameHolder)
                            .aspectRatio(viewModel.frameSize, contentMode: .fit)
                            .blur(radius: viewModel.isTransitioning ? 30 : 0)
                            .opacity(viewModel.isTransitioning ? 0.6 : 1.0)

                        TouchOverlayView(
                            onTouchEvent: { event in
                                resetIdleTimer()
                                viewModel.sendTouchEvent(event)
                            },
                            onScrollEvent: { deltaX, deltaY, x, y in
                                resetIdleTimer()
                                viewModel.sendScrollEvent(deltaX: deltaX, deltaY: deltaY, x: x, y: y)
                            },
                            onRightClickEvent: { x, y in
                                resetIdleTimer()
                                viewModel.sendRightClickEvent(x: x, y: y)
                            },
                            onPencilEvent: { event in
                                resetIdleTimer()
                                if enableApplePencil {
                                    viewModel.sendPencilEvent(event)
                                }
                            },
                            onPencilInteractionEvent: { event in
                                resetIdleTimer()
                                if enableApplePencil {
                                    viewModel.sendPencilInteractionEvent(event)
                                }
                            }
                        )
                    }
                    .edgesIgnoringSafeArea(.all)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in resetIdleTimer() }
                    )

                    // Disconnect overlay button
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: viewModel.disconnect) {
                                HStack(spacing: 8) {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Disconnect")
                                }
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule()
                                        .fill(Color.red.opacity(0.85))
                                        .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                                )
                            }
                            .padding()
                            .opacity(isIdle ? 0.0 : 1.0)
                            .allowsHitTesting(!isIdle)
                        }
                        Spacer()
                    }
                } else {
                // Device Discovery & Setup Screen (Premium Glassmorphism Style)
                ZStack {
                    // Deep futuristic background
                    LinearGradient(gradient: Gradient(colors: [Color(hex: "0B0F19"), Color(hex: "1A233A")]), startPoint: .topLeading, endPoint: .bottomTrailing)
                        .edgesIgnoringSafeArea(.all)

                    // Subtle glowing ambient light
                    VStack {
                        HStack {
                            Circle()
                                .fill(Color.indigo.opacity(0.15))
                                .frame(width: 300, height: 300)
                                .blur(radius: 80)
                            Spacer()
                        }
                        Spacer()
                        HStack {
                            Spacer()
                            Circle()
                                .fill(Color.emerald.opacity(0.12))
                                .frame(width: 350, height: 350)
                                .blur(radius: 90)
                        }
                    }
                    .edgesIgnoringSafeArea(.all)

                    ScrollView {
                        VStack(spacing: 32) {
                            // Settings Button Row
                            HStack {
                                Spacer()
                                Button(action: { showSettings = true }) {
                                    Image(systemName: "gearshape.fill")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                        .padding(12)
                                        .background(Color.white.opacity(0.08))
                                        .clipShape(Circle())
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 16)

                            // Header
                            VStack(spacing: 8) {
                                Image(systemName: "ipad")
                                    .font(.system(size: 64))
                                    .foregroundStyle(
                                        LinearGradient(colors: [.indigo, .emerald], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    )
                                    .padding(.bottom, 8)

                                Text("X-Display")
                                    .font(.system(size: 38, weight: .black, design: .rounded))
                                    .foregroundColor(.white)

                                Text("Secondary Display Receiver")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.gray)
                            }
                            .padding(.top, 40)

                            // Bonjour Scan Section
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("Discovered Displays")
                                        .font(.headline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)

                                    Spacer()

                                    // Scanning Indicator
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .tint(.gray)
                                            .scaleEffect(0.7)
                                        Text("Scanning...")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                    }
                                }
                                .padding(.horizontal, 8)

                                if viewModel.discoveredDevices.isEmpty {
                                    // Empty State Card
                                    VStack(spacing: 16) {
                                        Image(systemName: "wifi")
                                            .font(.largeTitle)
                                            .foregroundColor(.gray.opacity(0.6))

                                        Text("Searching for Mac hosts on your local network...")
                                            .font(.footnote)
                                            .foregroundColor(.gray)
                                            .multilineTextAlignment(.center)
                                            .padding(.horizontal, 32)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 40)
                                    .background(
                                        RoundedRectangle(cornerRadius: 16)
                                            .fill(Color.white.opacity(0.03))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 16)
                                                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                                            )
                                    )
                                } else {
                                    // Discovered Device Cards
                                    VStack(spacing: 12) {
                                        ForEach(viewModel.discoveredDevices) { device in
                                            Button(action: { viewModel.connect(endpoint: device.endpoint, type: device.type) }) {
                                                HStack {
                                                    Image(systemName: "macmini.fill")
                                                        .font(.title2)
                                                        .foregroundColor(.emerald)
                                                        .padding(12)
                                                        .background(Color.emerald.opacity(0.1))
                                                        .cornerRadius(12)

                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text(device.name)
                                                            .font(.body)
                                                            .fontWeight(.bold)
                                                            .foregroundColor(.white)
                                                        Text("Bonjour Connection")
                                                            .font(.caption)
                                                            .foregroundColor(.gray)
                                                    }

                                                    Spacer()

                                                    Image(systemName: "chevron.right")
                                                        .font(.footnote)
                                                        .foregroundColor(.gray)
                                                }
                                                .padding()
                                                .background(
                                                    RoundedRectangle(cornerRadius: 16)
                                                        .fill(Color.white.opacity(0.05))
                                                        .overlay(
                                                            RoundedRectangle(cornerRadius: 16)
                                                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                                        )
                                                )
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: 480)

                            // Expandable Manual IP Connection
                            VStack(alignment: .leading, spacing: 16) {
                                Button(action: { withAnimation { showManualConnection.toggle() } }) {
                                    HStack {
                                        Text("Manual IP Connection")
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.indigo)

                                        Spacer()

                                        Image(systemName: showManualConnection ? "chevron.up" : "chevron.down")
                                            .font(.caption)
                                            .foregroundColor(.indigo)
                                    }
                                    .padding(.horizontal, 8)
                                }

                                if showManualConnection {
                                    VStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("IP Address")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundColor(.gray)

                                            TextField("192.168.1.100", text: $hostAddress)
                                                .textFieldStyle(PlainTextFieldStyle())
                                                .padding()
                                                .background(Color.white.opacity(0.05))
                                                .cornerRadius(10)
                                                .foregroundColor(.white)
                                                .keyboardType(.numbersAndPunctuation)
                                        }

                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Port")
                                                .font(.caption2)
                                                .fontWeight(.bold)
                                                .foregroundColor(.gray)

                                            TextField("12345", text: $hostPort)
                                                .textFieldStyle(PlainTextFieldStyle())
                                                .padding()
                                                .background(Color.white.opacity(0.05))
                                                .cornerRadius(10)
                                                .foregroundColor(.white)
                                                .keyboardType(.numberPad)
                                        }

                                        Button(action: connectManually) {
                                            Text("Connect")
                                                .font(.subheadline)
                                                .fontWeight(.bold)
                                                .foregroundColor(.black)
                                                .frame(maxWidth: .infinity)
                                                .padding()
                                                .background(Color.indigo)
                                                .cornerRadius(10)
                                        }
                                    }
                                    .padding()
                                    .background(
                                        RoundedRectangle(cornerRadius: 16)
                                            .fill(Color.white.opacity(0.02))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 16)
                                                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
                                            )
                                    )
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .frame(maxWidth: 480)

                            // Bottom Status
                            Text("Status: \(viewModel.connectionStatus)")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding(.bottom, 24)
                        }
                        .padding(.horizontal, 24)
                    }
                }
            }
        }
        .onChange(of: isPortrait) { newValue in
            viewModel.updateOrientation(isPortrait: newValue)
        }
        .onAppear {
            viewModel.updateOrientation(isPortrait: isPortrait)
            if viewModel.isConnected {
                resetIdleTimer()
            }
        }
        .onDisappear {
            idleTimerTask?.cancel()
        }
        }
        .statusBarHidden(isIdle)
        .persistentSystemOverlays(isIdle ? .hidden : .automatic)
        .onChange(of: viewModel.isConnected) { isConnected in
            if isConnected {
                resetIdleTimer()
            } else {
                idleTimerTask?.cancel()
                isIdle = false
            }
        }
        .sheet(isPresented: $viewModel.isPairingRequired) {
            PINEntryView(pin: $viewModel.enteredPIN) {
                viewModel.submitPIN()
            } onCancel: {
                viewModel.disconnect()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: selectedCodec) { _ in
            if viewModel.isConnected {
                viewModel.sendClientInfo()
            }
        }
        .onChange(of: maxFrameRate) { _ in
            if viewModel.isConnected {
                viewModel.sendClientInfo()
            }
        }
    }

    private func connectManually() {
        guard !hostAddress.isEmpty else {
            viewModel.connectionStatus = "IP required"
            return
        }
        guard let port = UInt16(hostPort) else {
            viewModel.connectionStatus = "Invalid port"
            return
        }
        viewModel.connect(host: hostAddress, port: port)
    }
}

// Beautiful Emerald green
extension Color {
    static let emerald = Color(hex: "10B981")

    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct StreamViewport: View {
    let frameHolder: FrameHolder

    var body: some View {
        MetalRendererView(frameHolder: frameHolder)
    }
}

struct PINEntryView: View {
    @Binding var pin: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color(hex: "0B0F19").edgesIgnoringSafeArea(.all)

            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(colors: [.indigo, .emerald],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing)
                        )

                    Text("Enter Pairing PIN")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Check the Mac terminal for a 4-digit PIN")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    TextField("0000", text: $pin)
                        .keyboardType(.numberPad)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .frame(maxWidth: 200)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.indigo.opacity(0.6), lineWidth: 1)
                                )
                        )
                }

                VStack(spacing: 12) {
                    Button(action: onSubmit) {
                        Text("Connect")
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(maxWidth: 280)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(Color.indigo)
                            )
                    }
                    .disabled(pin.count < 4)
                    .opacity(pin.count < 4 ? 0.5 : 1.0)

                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(40)
        }
    }
}
