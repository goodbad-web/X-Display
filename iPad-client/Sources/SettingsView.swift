import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss

    // Persisted settings using @AppStorage (UserDefaults)
    @AppStorage("selectedCodec") private var selectedCodec = "HEVC"
    @AppStorage("maxFrameRate") private var maxFrameRate = 60
    @AppStorage("enableApplePencil") private var enableApplePencil = true
    @AppStorage("idleTimeoutSeconds") private var idleTimeoutSeconds = 5

    var body: some View {
        NavigationStack {
            ZStack {
                // Futuristic dark background matching app style
                LinearGradient(
                    gradient: Gradient(colors: [Color(hex: "0B0F19"), Color(hex: "131A2C")]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .edgesIgnoringSafeArea(.all)

                Form {
                    Section {
                        HStack {
                            Image(systemName: "video.fill")
                                .foregroundColor(.indigo)
                                .frame(width: 24)
                            Picker("Video Codec", selection: $selectedCodec) {
                                Text("HEVC (H.265)").tag("HEVC")
                                Text("H.264").tag("H.264")
                            }
                            .foregroundColor(.white)
                        }
                        .listRowBackground(Color.white.opacity(0.05))

                        HStack {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.emerald)
                                .frame(width: 24)
                            Picker("Target Frame Rate", selection: $maxFrameRate) {
                                Text("30 FPS").tag(30)
                                Text("60 FPS").tag(60)
                            }
                            .foregroundColor(.white)
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    } header: {
                        Text("Video & Streaming")
                            .foregroundColor(.gray)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }

                    Section {
                        HStack {
                            Image(systemName: "applepencil")
                                .foregroundColor(.indigo)
                                .frame(width: 24)
                            Toggle("Enable Apple Pencil Input", isOn: $enableApplePencil)
                                .tint(.indigo)
                                .foregroundColor(.white)
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    } header: {
                        Text("Input & Stylus")
                            .foregroundColor(.gray)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }

                    Section {
                        HStack {
                            Image(systemName: "eye.slash.fill")
                                .foregroundColor(.emerald)
                                .frame(width: 24)
                            Stepper("Auto-hide Controls: \(idleTimeoutSeconds)s", value: $idleTimeoutSeconds, in: 3...15)
                                .foregroundColor(.white)
                        }
                        .listRowBackground(Color.white.opacity(0.05))
                    } header: {
                        Text("Interface & System UI")
                            .foregroundColor(.gray)
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                }
                .scrollContentBackground(.hidden) // Make form background transparent to show gradient
            }
            .navigationTitle("X-Display Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { dismiss() }) {
                        Text("Done")
                            .fontWeight(.bold)
                            .foregroundColor(.indigo)
                    }
                }
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .preferredColorScheme(.dark)
    }
}
