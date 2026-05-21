import SwiftUI
import MetalKit
import CoreVideo

struct MetalRendererView: UIViewRepresentable {
    let frameHolder: FrameHolder

    func makeUIView(context: Context) -> MTKView {
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

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.attach(to: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(frameHolder: frameHolder)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.detach()
    }

    class Coordinator: NSObject, MTKViewDelegate {
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
