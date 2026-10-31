import Metal
import simd

/// Renders the mesh depth from one keyframe on the GPU. View selection samples this buffer instead of rasterizing every triangle on the CPU.
enum FaceVisibility {
    static func depthMap(mesh: ScanMesh, frame: StoredKeyframe, width: Int = 160) -> DepthImage? {
        Renderer.shared?.render(mesh: mesh, frame: frame, width: width)
    }

    private final class Renderer {
        static let shared = Renderer()
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState

        init?() {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let library = try? device.makeDefaultLibrary(bundle: .main),
                  let vertex = library.makeFunction(name: "visibilityVertex"),
                  let fragment = library.makeFunction(name: "visibilityFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .r32Float
            descriptor.depthAttachmentPixelFormat = .depth32Float
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
            self.device = device
            self.queue = queue
            self.pipeline = pipeline
        }

        func render(mesh: ScanMesh, frame: StoredKeyframe, width: Int) -> DepthImage? {
            let height = max(1, width * max(frame.height, 1) / max(frame.width, 1))
            let scaleX = Float(width) / Float(max(frame.width, 1))
            let scaleY = Float(height) / Float(max(frame.height, 1))
            var view = frame.viewMatrix
            var camera = [
                frame.fx * scaleX, frame.fy * scaleY, frame.cx * scaleX, frame.cy * scaleY,
                Float(width), Float(height), Float(8)
            ]
            var packed = [Float]()
            packed.reserveCapacity(mesh.positions.count * 3)
            for position in mesh.positions {
                packed.append(position.x)
                packed.append(position.y)
                packed.append(position.z)
            }
            guard let positions = device.makeBuffer(bytes: packed, length: packed.count * 4, options: .storageModeShared),
                  let indices = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 4, options: .storageModeShared),
                  let texture = device.makeTexture(descriptor: {
                      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
                      descriptor.usage = [.renderTarget, .shaderRead]
                      descriptor.storageMode = .shared
                      return descriptor
                  }()),
                  let depthTexture = device.makeTexture(descriptor: {
                      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
                      descriptor.usage = [.renderTarget]
                      descriptor.storageMode = .private
                      return descriptor
                  }()),
                  let depthState = device.makeDepthStencilState(descriptor: {
                      let descriptor = MTLDepthStencilDescriptor()
                      descriptor.depthCompareFunction = .less
                      descriptor.isDepthWriteEnabled = true
                      return descriptor
                  }()),
                  let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: {
                      let pass = MTLRenderPassDescriptor()
                      pass.colorAttachments[0].texture = texture
                      pass.colorAttachments[0].loadAction = .clear
                      pass.colorAttachments[0].storeAction = .store
                      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                      pass.depthAttachment.texture = depthTexture
                      pass.depthAttachment.loadAction = .clear
                      pass.depthAttachment.storeAction = .dontCare
                      pass.depthAttachment.clearDepth = 1
                      return pass
                  }()) else { return nil }
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(indices, offset: 0, index: 1)
            encoder.setVertexBytes(&view, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            encoder.setVertexBytes(&camera, length: camera.count * 4, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.indices.count)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { return nil }
            var values = [Float](repeating: 0, count: width * height)
            values.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return DepthImage(values: values, width: width, height: height)
        }
    }
}
