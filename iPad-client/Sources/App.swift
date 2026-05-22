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
    @AppStorage("enableEnergySaving") private var enableEnergySaving = false

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

                if viewModel.isPairingRequired {
                    PINEntryView(pin: $viewModel.enteredPIN) {
                        viewModel.submitPIN()
                    } onCancel: {
                        viewModel.disconnect()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                if let hostPin = viewModel.hostGeneratedPIN {
                    HostPINDisplayView(pin: hostPin) {
                        viewModel.disconnect()
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                if viewModel.isScreenSaverActive {
                    Color.black
                        .edgesIgnoringSafeArea(.all)
                        .transition(.opacity)
                        .onTapGesture {
                            viewModel.registerActivity()
                        }
                }
            }
        }
        .onChange(of: isPortrait) { _, newValue in
            viewModel.updateOrientation(isPortrait: newValue)
        }
        .onAppear {
            viewModel.updateOrientation(isPortrait: isPortrait)
            if viewModel.isConnected {
                resetIdleTimer()
            }
        }
        .task {
            // Wait briefly for UI to fully render before triggering Local Network privacy checks
            try? await Task.sleep(nanoseconds: 500_000_000)
            viewModel.startDiscovery()
        }
        .onDisappear {
            idleTimerTask?.cancel()
        }
        }
        .statusBarHidden(isIdle || viewModel.isScreenSaverActive)
        .persistentSystemOverlays((isIdle || viewModel.isScreenSaverActive) ? .hidden : .automatic)
        .onChange(of: viewModel.isConnected) { _, isConnected in
            if isConnected {
                resetIdleTimer()
            } else {
                idleTimerTask?.cancel()
                isIdle = false
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onChange(of: selectedCodec) {
            if viewModel.isConnected {
                viewModel.sendClientInfo()
            }
        }
        .onChange(of: maxFrameRate) {
            if viewModel.isConnected {
                viewModel.sendClientInfo()
            }
        }
        .onChange(of: enableEnergySaving) {
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




struct PINEntryView: View {
    @Binding var pin: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        ZStack {
            // Tap background to dismiss keyboard
            Color(hex: "0B0F19")
                .ignoresSafeArea(.all)
                .onTapGesture {
                    isTextFieldFocused = false
                }

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
                        .focused($isTextFieldFocused)
                        .keyboardType(.asciiCapableNumberPad)
                        .submitLabel(.done)
                        .onSubmit {
                            if pin.count == 4 {
                                isTextFieldFocused = false
                                onSubmit()
                            }
                        }
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
                    Button(action: {
                        isTextFieldFocused = false
                        onSubmit()
                    }) {
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

                    Button(action: {
                        isTextFieldFocused = false
                        onCancel()
                    }) {
                        Text("Cancel")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.vertical, 8)
                            .frame(maxWidth: 280)
                    }
                }
            }
            .padding(40)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isTextFieldFocused = true
            }
        }
        .onChange(of: pin) { _, newValue in
            let filtered = newValue.filter { $0.isNumber }
            let truncated = String(filtered.prefix(4))
            
            if newValue != truncated {
                pin = truncated
            }
        }
    }
}

struct HostPINDisplayView: View {
    let pin: String
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color(hex: "0B0F19").ignoresSafeArea(.all)

            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Image(systemName: "display.and.macbook")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(colors: [.emerald, .indigo],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing)
                        )

                    Text("Mac is Connecting...")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("Enter this PIN on your Mac to complete pairing")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }

                Text(pin)
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 40)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.emerald.opacity(0.6), lineWidth: 2)
                            )
                    )

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 280)
                }
            }
            .padding(40)
        }
    }
}
