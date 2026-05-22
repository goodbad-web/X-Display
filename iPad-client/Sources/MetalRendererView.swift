import SwiftUI
import MetalKit
import CoreVideo

#if os(iOS)
typealias ViewRepresentable = UIViewRepresentable
#elseif os(macOS)
typealias ViewRepresentable = NSViewRepresentable
#endif

@MainActor
struct MetalRendererView: ViewRepresentable {
    let frameHolder: FrameHolder

    #if os(iOS)
    func makeUIView(context: Context) -> MTKView {
        makeView(context: context)
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        updateView(uiView, context: context)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        dismantleView(uiView, coordinator: coordinator)
    }
    #elseif os(macOS)
    func makeNSView(context: Context) -> MTKView {
        makeView(context: context)
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        updateView(nsView, context: context)
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        dismantleView(nsView, coordinator: coordinator)
    }
    #endif

    private func makeView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)

        // Passive rendering: draw only when a new frame is received
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true

        mtkView.delegate = context.coordinator

        context.coordinator.setupMetal(device: mtkView.device!)
        context.coordinator.attach(to: mtkView)
        return mtkView
    }

    private func updateView(_ view: MTKView, context: Context) {
        context.coordinator.attach(to: view)
    }

    private static func dismantleView(_ view: MTKView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(frameHolder: frameHolder)
    }

    @MainActor class Coordinator: NSObject, MTKViewDelegate {
        private let frameHolder: FrameHolder
        var pixelBuffer: CVPixelBuffer?
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var textureCache: CVMetalTextureCache?
        private let timingLock = NSLock()
        private var renderFrameCount = 0
        private var renderFrameTotalNs: UInt64 = 0
        private var renderFrameMaxNs: UInt64 = 0
        private var lastRenderLogTime = Date()
        private var lastRenderFrameCount = 0
        private let renderLock = NSLock()
        private var isRenderInFlight = false
        private var hasPendingRender = false

        init(frameHolder: FrameHolder) {
            self.frameHolder = frameHolder
        }

        func setupMetal(device: MTLDevice) {
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            // Build texture cache for zero-copy CVPixelBuffer-to-MetalTexture mapping
            let result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
            if result != kCVReturnSuccess {
                print("[-] CVMetalTextureCacheCreate failed: \(result)")
            }

            // Setup pipeline state using embedded shaders
            let defaultLibrary = device.makeDefaultLibrary()
            let vertexFunction = defaultLibrary?.makeFunction(name: "vertexMain")
            let fragmentFunction = defaultLibrary?.makeFunction(name: "fragmentMain")

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                print("[-] Failed to create pipeline state: \(error.localizedDescription)")
            }
        }

        func attach(to view: MTKView) {
            frameHolder.setRenderer { [weak self, weak view] pixelBuffer in
                guard let self = self, let view = view else { return }
                self.pixelBuffer = pixelBuffer
                self.requestDraw(on: view)
            }
        }

        func detach() {
            frameHolder.setRenderer(nil)
        }

        private func requestDraw(on view: MTKView) {
            renderLock.lock()
            if isRenderInFlight {
                hasPendingRender = true
                renderLock.unlock()
                return
            }
            isRenderInFlight = true
            renderLock.unlock()

            view.draw()
        }

        func draw(in view: MTKView) {
            let start = DispatchTime.now().uptimeNanoseconds
            guard let pixelBuffer = pixelBuffer,
                  let commandQueue = commandQueue,
                  let pipelineState = pipelineState,
                  let textureCache = textureCache else {
                finishRender(on: view)
                return
            }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            var cvMetalTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvMetalTexture
            )

            guard status == kCVReturnSuccess,
                  let metalTextureRef = cvMetalTexture,
                  let texture = CVMetalTextureGetTexture(metalTextureRef) else {
                print("[-] Failed to convert CVPixelBuffer to MTLTexture")
                finishRender(on: view)
                return
            }

            guard let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
                  let drawable = view.currentDrawable else {
                print("[-] Metal drawable unavailable; dropping frame.")
                finishRender(on: view)
                return
            }

            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setFragmentTexture(texture, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.addCompletedHandler { [weak self, weak view] _ in
                guard let self = self, let view = view else { return }
                DispatchQueue.main.async {
                    self.finishRender(on: view)
                }
            }
            commandBuffer.commit()
            
            // 不要になったテクスチャキャッシュを即座に解放し、メモリの肥大化とスパイクを防ぐ
            CVMetalTextureCacheFlush(textureCache, 0)
            
            recordRenderTiming(DispatchTime.now().uptimeNanoseconds - start)
        }

        private func finishRender(on view: MTKView) {
            renderLock.lock()
            let shouldDrawPending = hasPendingRender
            hasPendingRender = false
            isRenderInFlight = false
            if shouldDrawPending {
                isRenderInFlight = true
            }
            renderLock.unlock()

            if shouldDrawPending {
                view.draw()
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        private func recordRenderTiming(_ elapsedNs: UInt64) {
            timingLock.lock()
            renderFrameCount += 1
            renderFrameTotalNs += elapsedNs
            renderFrameMaxNs = max(renderFrameMaxNs, elapsedNs)
            let shouldLog = renderFrameCount % 60 == 0
            let averageMs = Double(renderFrameTotalNs) / Double(renderFrameCount) / 1_000_000.0
            let maxMs = Double(renderFrameMaxNs) / 1_000_000.0
            let now = Date()
            let interval = now.timeIntervalSince(lastRenderLogTime)
            let renderedDelta = renderFrameCount - lastRenderFrameCount
            if shouldLog {
                lastRenderLogTime = now
                lastRenderFrameCount = renderFrameCount
            }
            timingLock.unlock()

            if shouldLog {
                let elapsedMs = Double(elapsedNs) / 1_000_000.0
                let renderedFPS = interval > 0 ? Double(renderedDelta) / interval : 0
                print(String(format: "[Timing] render: %.2f ms (avg %.2f ms, max %.2f ms) | rendered FPS: %.1f", elapsedMs, averageMs, maxMs, renderedFPS))
            }
        }
    }
}

struct StreamViewport: View {
    let frameHolder: FrameHolder

    var body: some View {
        MetalRendererView(frameHolder: frameHolder)
    }
}

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
