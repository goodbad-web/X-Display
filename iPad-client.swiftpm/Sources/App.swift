import SwiftUI
import Network

@main
struct XDisplayClientApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppViewModel: ObservableObject, StreamClientDelegate, VideoDecoderDelegate {
    @Published var connectionStatus: String = "Disconnected"
    @Published var isConnected = false
    @Published var currentPixelBuffer: CVPixelBuffer? = nil
    
    private let streamClient = StreamClient()
    private let videoDecoder = VideoDecoder()
    
    init() {
        streamClient.delegate = self
        videoDecoder.delegate = self
    }
    
    func connect(host: String, port: UInt16) {
        connectionStatus = "Connecting..."
        streamClient.connect(host: host, port: port)
    }
    
    func disconnect() {
        streamClient.disconnect()
        isConnected = false
        connectionStatus = "Disconnected"
        currentPixelBuffer = nil
    }
    
    func sendTouchEvent(_ event: TouchEvent) {
        streamClient.sendInputEvent(phase: event.phase, x: event.x, y: event.y, pressure: event.pressure)
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
            case .waiting(let error):
                self.connectionStatus = "Waiting: \(error.localizedDescription)"
            case .ready:
                self.connectionStatus = "Connected"
                self.isConnected = true
            case .failed(let error):
                self.connectionStatus = "Failed: \(error.localizedDescription)"
                self.isConnected = false
            case .cancelled:
                self.connectionStatus = "Disconnected"
                self.isConnected = false
            @unknown default:
                break
            }
        }
    }
    
    // VideoDecoderDelegate
    func videoDecoder(_ decoder: VideoDecoder, didDecodeImageBuffer pixelBuffer: CVPixelBuffer) {
        DispatchQueue.main.async {
            self.currentPixelBuffer = pixelBuffer
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var hostAddress: String = "192.168.1.100" // Default placeholder IP
    @State private var hostPort: String = "12345"
    
    var body: some View {
        ZStack {
            if viewModel.isConnected {
                // Video streaming view with touch overlay capture
                ZStack {
                    MetalRendererView(currentPixelBuffer: $viewModel.currentPixelBuffer)
                    
                    TouchOverlayView { event in
                        viewModel.sendTouchEvent(event)
                    }
                }
                .edgesIgnoringSafeArea(.all)
                
                // Floating Disconnect button for quick escape
                VStack {
                    HStack {
                        Spacer()
                        Button(action: viewModel.disconnect) {
                            Text("Disconnect")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(8)
                        }
                        .padding()
                    }
                    Spacer()
                }
            } else {
                // Setup / Connection Screen with beautiful dark mode aesthetics
                VStack(spacing: 24) {
                    Text("X-Display Client")
                        .font(.largeTitle)
                        .fontWeight(.heavy)
                        .foregroundColor(.white)
                        
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mac Host IP Address")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.gray)
                        
                        TextField("e.g. 192.168.1.100", text: $hostAddress)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(8)
                            .foregroundColor(.white)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    .frame(maxWidth: 320)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Port Number")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.gray)
                        
                        TextField("12345", text: $hostPort)
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(8)
                            .foregroundColor(.white)
                            .keyboardType(.numberPad)
                    }
                    .frame(maxWidth: 320)
                    
                    Button(action: connect) {
                        Text("Connect to Mac")
                            .fontWeight(.semibold)
                            .foregroundColor(.black)
                            .frame(maxWidth: 320)
                            .padding()
                            .background(Color.green)
                            .cornerRadius(8)
                    }
                    
                    Text("Status: \(viewModel.connectionStatus)")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.edgesIgnoringSafeArea(.all))
            }
        }
        .onDisappear {
            viewModel.disconnect()
        }
    }
    
    private func connect() {
        guard let port = UInt16(hostPort) else {
            viewModel.connectionStatus = "Invalid port"
            return
        }
        viewModel.connect(host: hostAddress, port: port)
    }
}
