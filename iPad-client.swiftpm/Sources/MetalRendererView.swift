import SwiftUI
import MetalKit
import CoreVideo

struct MetalRendererView: UIViewRepresentable {
    @Binding var currentPixelBuffer: CVPixelBuffer?
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        mtkView.delegate = context.coordinator
        
        context.coordinator.setupMetal(device: mtkView.device!)
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.pixelBuffer = currentPixelBuffer
        uiView.draw()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        var pixelBuffer: CVPixelBuffer?
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var textureCache: CVMetalTextureCache?
        
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
        
        func draw(in view: MTKView) {
            guard let pixelBuffer = pixelBuffer,
                  let device = device,
                  let commandQueue = commandQueue,
                  let pipelineState = pipelineState,
                  let textureCache = textureCache else { return }
            
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
                return
            }
            
            guard let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
            
            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setFragmentTexture(texture, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
            
            if let drawable = view.currentDrawable {
                commandBuffer.present(drawable)
            }
            
            commandBuffer.commit()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    }
}
