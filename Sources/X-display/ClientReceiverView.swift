#if os(macOS)
import SwiftUI
import AppKit
import Network
import XDisplayShared

class ClientReceiverWindowController: NSWindowController, NSWindowDelegate {
    static var shared: ClientReceiverWindowController?
    
    static func open() {
        if let shared = shared {
            shared.window?.makeKeyAndOrderFront(nil)
            return
        }
        
        let viewModel = AppViewModel()
        let receiverView = ClientReceiverView(viewModel: viewModel)
        
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "X-Display Receiver"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1.0)
        window.minSize = NSSize(width: 640, height: 360)
        
        let hostingView = NSHostingView(rootView: receiverView)
        window.contentView = hostingView
        
        let controller = ClientReceiverWindowController(window: window)
        window.delegate = controller
        self.shared = controller
        
        window.makeKeyAndOrderFront(nil)
        viewModel.startDiscovery()
    }
    
    func windowWillClose(_ notification: Notification) {
        if let hostingView = window?.contentView as? NSHostingView<ClientReceiverView> {
            hostingView.rootView.viewModel.disconnect()
        }
        ClientReceiverWindowController.shared = nil
    }
}

struct ClientReceiverView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var hostAddress: String = ""
    @State private var hostPort: String = "12345"
    @State private var showManualConnection = false
    
    var body: some View {
        ZStack {
            // Deep dark futuristic background
            Color(hex: "0B0F19")
                .edgesIgnoringSafeArea(.all)
            
            if viewModel.isConnected {
                // Video stream rendering
                ZStack {
                    StreamViewport(frameHolder: viewModel.frameHolder)
                        .aspectRatio(viewModel.frameSize, contentMode: .fit)
                        .blur(radius: viewModel.isTransitioning ? 20 : 0)
                        .opacity(viewModel.isTransitioning ? 0.6 : 1.0)
                    
                    // Floating Disconnect Button at top-right
                    VStack {
                        HStack {
                            Spacer()
                            Button(action: {
                                viewModel.disconnect()
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Disconnect")
                                }
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(16)
                        }
                        Spacer()
                    }
                }
            } else {
                // Connection setup view
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 48))
                            .foregroundStyle(
                                LinearGradient(colors: [.indigo, .emerald], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        
                        Text("X-Display Receiver")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("Receive screen streams from other Mac hosts")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 32)
                    
                    // Bonjour devices list
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Available Displays")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            HStack(spacing: 4) {
                                ProgressView()
                                    .scaleEffect(0.5)
                                Text("Scanning...")
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.horizontal, 8)
                        
                        if viewModel.discoveredDevices.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "wifi")
                                    .font(.system(size: 24))
                                    .foregroundColor(.gray.opacity(0.5))
                                Text("Looking for other Mac hosts on local network...")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                            .background(Color.white.opacity(0.02))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
                            )
                        } else {
                            ScrollView {
                                VStack(spacing: 8) {
                                    ForEach(viewModel.discoveredDevices) { device in
                                        Button(action: {
                                            viewModel.connect(endpoint: device.endpoint, type: device.type)
                                        }) {
                                            HStack {
                                                Image(systemName: "macmini.fill")
                                                    .foregroundColor(.emerald)
                                                    .padding(8)
                                                    .background(Color.emerald.opacity(0.1))
                                                    .cornerRadius(8)
                                                
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(device.name)
                                                        .font(.system(size: 13, weight: .bold))
                                                        .foregroundColor(.white)
                                                    Text(device.type == .wired ? "Thunderbolt / USB" : "Wi-Fi")
                                                        .font(.system(size: 10))
                                                        .foregroundColor(.gray)
                                                }
                                                
                                                Spacer()
                                                
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 10))
                                                    .foregroundColor(.gray)
                                            }
                                            .padding(10)
                                            .background(Color.white.opacity(0.04))
                                            .cornerRadius(10)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }
                            .frame(maxHeight: 180)
                        }
                    }
                    .frame(width: 400)
                    
                    // Manual Connection
                    VStack(spacing: 8) {
                        Button(action: {
                            withAnimation {
                                showManualConnection.toggle()
                            }
                        }) {
                            HStack {
                                Text("Manual IP Connection")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.indigo)
                                Spacer()
                                Image(systemName: showManualConnection ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundColor(.indigo)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal, 8)
                        
                        if showManualConnection {
                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("IP Address")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.gray)
                                        TextField("192.168.1.100", text: $hostAddress)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Port")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.gray)
                                        TextField("12345", text: $hostPort)
                                            .textFieldStyle(RoundedBorderTextFieldStyle())
                                    }
                                }
                                
                                Button(action: {
                                    if let portVal = UInt16(hostPort) {
                                        viewModel.connect(host: hostAddress, port: portVal)
                                    }
                                }) {
                                    Text("Connect")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.black)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(Color.indigo)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.02))
                            .cornerRadius(10)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .frame(width: 400)
                    
                    // Status Footer
                    Text("Status: \(viewModel.connectionStatus)")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .padding(.bottom, 20)
                }
            }
            
            // Overlays for PIN entry
            if viewModel.isPairingRequired {
                Color.black.opacity(0.6)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 16) {
                    Text("Enter PIN")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("Enter the pairing PIN displayed on the streaming host Mac.")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                    
                    SecureField("PIN", text: $viewModel.enteredPIN)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 120)
                        .multilineTextAlignment(.center)
                    
                    HStack(spacing: 12) {
                        Button("Cancel") {
                            viewModel.disconnect()
                        }
                        .buttonStyle(BorderedButtonStyle())
                        
                        Button("Submit") {
                            viewModel.submitPIN()
                        }
                        .buttonStyle(BorderedProminentButtonStyle())
                    }
                }
                .padding(24)
                .background(Color(hex: "131A2C"))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .frame(width: 320)
            }
            
            if let hostPin = viewModel.hostGeneratedPIN {
                Color.black.opacity(0.6)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 16) {
                    Text("Pairing PIN")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("Enter this PIN on the client device:")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    
                    Text(hostPin)
                        .font(.system(size: 32, weight: .black, design: .monospaced))
                        .foregroundColor(.emerald)
                        .tracking(8)
                    
                    Button("Cancel") {
                        viewModel.disconnect()
                    }
                    .buttonStyle(BorderedButtonStyle())
                }
                .padding(24)
                .background(Color(hex: "131A2C"))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .frame(width: 320)
            }
        }
    }
}
#endif
