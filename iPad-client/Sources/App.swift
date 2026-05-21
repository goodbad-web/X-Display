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
    let frameHolder = FrameHolder()
    @Published var discoveredDevices: [DiscoveredDevice] = []

    private let streamClient = StreamClient()
    private let videoDecoder = VideoDecoder()
    private let deviceBrowser = DeviceBrowser()

    init() {
        streamClient.delegate = self
        videoDecoder.delegate = self

        // Bind Bonjour browser results
        deviceBrowser.$discoveredDevices
            .assign(to: &$discoveredDevices)

        deviceBrowser.startBrowsing()
    }

    func connect(endpoint: NWEndpoint) {
        deviceBrowser.stopBrowsing()
        connectionStatus = "Connecting..."
        videoDecoder.reset()
        streamClient.connect(endpoint: endpoint)
    }

    func connect(host: String, port: UInt16) {
        deviceBrowser.stopBrowsing()
        connectionStatus = "Connecting..."
        videoDecoder.reset()
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
        deviceBrowser.startBrowsing()
    }

    func submitPIN() {
        streamClient.submitPIN(enteredPIN)
        enteredPIN = ""
    }

    func sendTouchEvent(_ event: TouchEvent) {
        streamClient.sendInputEvent(phase: event.phase, x: event.x, y: event.y, pressure: event.pressure)
    }

    func sendScrollEvent(deltaX: Float, deltaY: Float) {
        streamClient.sendScrollEvent(deltaX: deltaX, deltaY: deltaY)
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



    // StreamClientDelegate
    func streamClient(_ client: StreamClient, didReceiveNALUnit data: Data) {
        videoDecoder.decode(data: data)
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
                self.connectionStatus = "Failed: \(error.localizedDescription)"
                self.isConnected = false
                self.isPairingRequired = false
                self.deviceBrowser.startBrowsing()
            case .cancelled:
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

    func streamClient(_ client: StreamClient, didFinishPairingWithResult success: Bool) {
        DispatchQueue.main.async {
            self.isPairingRequired = false
            self.connectionStatus = success ? "Connected" : "Pairing failed"
            self.isConnected = success
            if !success {
                self.disconnect()
            }
        }
    }

    // VideoDecoderDelegate
    func videoDecoder(_ decoder: VideoDecoder, didDecodeImageBuffer pixelBuffer: CVPixelBuffer) {
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

    var body: some View {
        ZStack {
            if viewModel.isConnected {
                // Zero-Latency Video streaming viewport with touch overlay
                ZStack {
                    StreamViewport(frameHolder: viewModel.frameHolder)

                    TouchOverlayView(
                        onTouchEvent: { event in
                            viewModel.sendTouchEvent(event)
                        },
                        onScrollEvent: { deltaX, deltaY in
                            viewModel.sendScrollEvent(deltaX: deltaX, deltaY: deltaY)
                        },
                        onRightClickEvent: { x, y in
                            viewModel.sendRightClickEvent(x: x, y: y)
                        },
                        onPencilEvent: { event in
                            viewModel.sendPencilEvent(event)
                        },
                        onPencilInteractionEvent: { event in
                            viewModel.sendPencilInteractionEvent(event)
                        }
                    )

                }
                .edgesIgnoringSafeArea(.all)

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
                                            Button(action: { viewModel.connect(endpoint: device.endpoint) }) {
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
        .sheet(isPresented: $viewModel.isPairingRequired) {
            PINEntryView(pin: $viewModel.enteredPIN) {
                viewModel.submitPIN()
            } onCancel: {
                viewModel.disconnect()
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
