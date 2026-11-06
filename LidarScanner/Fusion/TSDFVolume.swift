import Foundation
import Metal
import simd

struct TSDFVoxel {
    var sdf: Float
    var weight: Float
}

struct TSDFParams {
    var worldToCamera: simd_float4x4 = matrix_identity_float4x4
    var fx: Float = 0
    var fy: Float = 0
    var cx: Float = 0
    var cy: Float = 0
    var voxel: Float = 0.01
    var trunc: Float = 0.04
    var minRange: Float = 0.3
    var maxRange: Float = 3
    var minConfidence: Float = 2
    var depthWidth: Float = 0
    var depthHeight: Float = 0
    var centerX: Float = 0
    var centerY: Float = 0
    var centerZ: Float = 0
    var radius: Float = 0
}

private struct BlockKey: Hashable {
    var x: Int32
    var y: Int32
    var z: Int32
}

private struct BlockRefCPU {
    var x: Int32
    var y: Int32
    var z: Int32
    var index: Int32
}

enum TSDFFusion {
    static func fuse(
        directory: URL,
        frames: [StoredKeyframe],
        settings: FusionSettings,
        objectCenter: SIMD3<Float>?,
        objectRadius: Float,
        signal: WorkSignal?,
        progress: ((Double) -> Void)?,
        useMetal: Bool = true
    ) -> ScanMesh {
        let volume = TSDFVolume(voxel: settings.voxelSize, truncation: settings.truncation, useMetal: useMetal)
        let usable = frames.filter { $0.depthWidth > 1 && $0.depthHeight > 1 }
        guard !usable.isEmpty else { return ScanMesh() }
        // Nearer views first, so a desk fills the volume before a distant floor does.
        let ordered = usable.map { ($0, nearer($0, directory: directory)) }
            .sorted { $0.1 < $1.1 }.map { $0.0 }
        for (index, frame) in ordered.enumerated() {
            if signal?.isCancelled == true { break }
            guard let (depth, confidence) = try? KeyframeArchive.readDepth(at: KeyframeArchive.depthURL(in: directory, index: frame.index)) else {
                continue
            }
            let filtered = DepthFilter.bilateral(depth)
            volume.integrate(
                frame: frame,
                depth: filtered,
                confidence: confidence,
                settings: settings,
                objectCenter: objectCenter,
                objectRadius: objectRadius
            )
            progress?(Double(index + 1) / Double(usable.count))
        }
        return volume.extract()
    }

    private static func nearer(_ frame: StoredKeyframe, directory: URL) -> Float {
        guard let loaded = try? KeyframeArchive.readDepth(at: KeyframeArchive.depthURL(in: directory, index: frame.index)) else { return 99 }
        let values = loaded.0.values
        let step = max(1, values.count / 300)
        var samples: [Float] = []
        var index = 0
        while index < values.count {
            let value = values[index]
            if value > 0.2, value < 5 { samples.append(value) }
            index += step
        }
        guard !samples.isEmpty else { return 99 }
        samples.sort()
        return samples[samples.count / 2]
    }
}

private final class TSDFVolume {
    let voxel: Float
    let truncation: Float
    let blockSize = 8
    let maxBlocks = 32_000
    private var lookup: [BlockKey: Int] = [:]
    private var origins: [BlockKey] = []
    private var pointer: UnsafeMutablePointer<TSDFVoxel>
    private var metal: TSDFMetal?

    init(voxel: Float, truncation: Float, useMetal: Bool) {
        self.voxel = voxel
        self.truncation = truncation
        let count = maxBlocks * 512
        pointer = UnsafeMutablePointer<TSDFVoxel>.allocate(capacity: count)
        for index in 0..<count {
            pointer[index] = TSDFVoxel(sdf: 1, weight: 0)
        }
        metal = useMetal ? TSDFMetal(capacity: count) : nil
        if let metal {
            metal.reset(pointer, count: count)
        }
    }

    deinit {
        pointer.deallocate()
    }

    func integrate(
        frame: StoredKeyframe,
        depth: DepthImage,
        confidence: [UInt8],
        settings: FusionSettings,
        objectCenter: SIMD3<Float>?,
        objectRadius: Float
    ) {
        let scaleX = Float(depth.width) / Float(max(frame.width, 1))
        let scaleY = Float(depth.height) / Float(max(frame.height, 1))
        var touched: [BlockRefCPU] = []
        var seen = Set<Int>()
        let step = max(1, (depth.width * depth.height) / 70_000)
        var pixel = 0
        let limit = depth.width * depth.height
        while pixel < limit {
            let x = pixel % depth.width
            let y = pixel / depth.width
            let meters = depth.values[pixel]
            let conf = pixel < confidence.count ? confidence[pixel] : 2
            if meters.isFinite, meters >= 0.3, meters <= settings.maxRange,
               Float(conf) >= settings.confidenceFloor {
                let world = CameraProjection.worldPoint(
                    u: (Float(x) + 0.5) / scaleX,
                    v: (Float(y) + 0.5) / scaleY,
                    depth: meters,
                    fx: frame.fx,
                    fy: frame.fy,
                    cx: frame.cx,
                    cy: frame.cy,
                    cameraToWorld: frame.cameraToWorld
                )
                if let center = objectCenter, objectRadius > 0,
                   simd_distance(world, center) > objectRadius + truncation {
                    pixel += step
                    continue
                }
                let origin = frame.cameraPosition
                let direction = world - origin
                let length = simd_length(direction)
                if length > 0.05 {
                    let ray = direction / length
                    let behind = max(1, Int(ceil(truncation / voxel)))
                    let ahead = behind * 2
                    for offset in -ahead...behind {
                        let sample = world + ray * (Float(offset) * voxel)
                        if let index = ensureBlock(containing: sample), seen.insert(index).inserted {
                            let key = origins[index]
                            touched.append(BlockRefCPU(x: key.x, y: key.y, z: key.z, index: Int32(index)))
                        }
                    }
                }
            }
            pixel += step
        }
        guard !touched.isEmpty else { return }
        var params = TSDFParams()
        params.worldToCamera = frame.viewMatrix
        params.fx = frame.fx * scaleX
        params.fy = frame.fy * scaleY
        params.cx = frame.cx * scaleX
        params.cy = frame.cy * scaleY
        params.voxel = voxel
        params.trunc = truncation
        params.minRange = 0.3
        params.maxRange = settings.maxRange
        params.minConfidence = settings.confidenceFloor
        params.depthWidth = Float(depth.width)
        params.depthHeight = Float(depth.height)
        if let objectCenter, objectRadius > 0.05 {
            params.centerX = objectCenter.x
            params.centerY = objectCenter.y
            params.centerZ = objectCenter.z
            params.radius = objectRadius
        }
        if metal?.integrate(blocks: touched, params: params, depth: depth, confidence: confidence, voxels: pointer) == true {
            return
        }
        integrateCPU(blocks: touched, params: params, depth: depth, confidence: confidence)
    }

    func extract() -> ScanMesh {
        MarchingCubes.extract(pointer: pointer, origins: origins.map { ($0.x, $0.y, $0.z) }, lookup: { key in
            self.lookup[BlockKey(x: key.0, y: key.1, z: key.2)]
        }, voxel: voxel, blockSize: blockSize)
    }

    private func ensureBlock(containing world: SIMD3<Float>) -> Int? {
        let key = blockKey(world)
        if let existing = lookup[key] { return existing }
        guard origins.count < maxBlocks else { return nil }
        let index = origins.count
        lookup[key] = index
        origins.append(key)
        let base = pointer.advanced(by: index * 512)
        for offset in 0..<512 {
            base[offset] = TSDFVoxel(sdf: 1, weight: 0)
        }
        metal?.resetBlock(index, pointer: pointer)
        return index
    }

    private func depthAt(_ depth: DepthImage, _ x: Int, _ y: Int) -> Float? {
        guard x >= 0, y >= 0, x < depth.width, y < depth.height else { return nil }
        let value = depth.values[y * depth.width + x]
        return value > 0.05 ? value : nil
    }

    private func blockKey(_ world: SIMD3<Float>) -> BlockKey {
        let inverse = 1 / (voxel * Float(blockSize))
        return BlockKey(
            x: Int32(floor(world.x * inverse)),
            y: Int32(floor(world.y * inverse)),
            z: Int32(floor(world.z * inverse))
        )
    }

    private func integrateCPU(blocks: [BlockRefCPU], params: TSDFParams, depth: DepthImage, confidence: [UInt8]) {
        for block in blocks {
            for local in 0..<512 {
                let lx = local % 8
                let ly = (local / 8) % 8
                let lz = local / 64
                let world = SIMD3<Float>(
                    (Float(block.x) * 8 + Float(lx) + 0.5) * voxel,
                    (Float(block.y) * 8 + Float(ly) + 0.5) * voxel,
                    (Float(block.z) * 8 + Float(lz) + 0.5) * voxel
                )
                if params.radius > 0.05 {
                    let center = SIMD3(params.centerX, params.centerY, params.centerZ)
                    if simd_distance(world, center) > params.radius { continue }
                }
                let camera = params.worldToCamera * SIMD4(world.x, world.y, world.z, 1)
                guard let pixel = CameraProjection.pixel(cameraX: camera.x, cameraY: camera.y, cameraZ: camera.z, fx: params.fx, fy: params.fy, cx: params.cx, cy: params.cy) else { continue }
                let cameraDepth = -camera.z
                guard cameraDepth >= params.minRange, cameraDepth <= params.maxRange else { continue }
                let x = Int(pixel.x)
                let y = Int(pixel.y)
                guard x >= 1, y >= 1, x < depth.width - 1, y < depth.height - 1 else { continue }
                let surface = depth.values[y * depth.width + x]
                guard surface >= params.minRange, surface <= params.maxRange else { continue }
                let sampleIndex = y * depth.width + x
                let conf = Float(sampleIndex < confidence.count ? confidence[sampleIndex] : 0)
                guard conf >= params.minConfidence else { continue }
                let signedDistance = surface - cameraDepth
                let slot = pointer.advanced(by: Int(block.index) * 512 + local)
                // A farther surface must not carve away a nearer one already stored here.
                if signedDistance > params.trunc, slot.pointee.weight > 1, slot.pointee.sdf < 0.5 { continue }
                guard signedDistance >= -params.trunc else { continue }
                let tsdf = min(1, max(-1, signedDistance / params.trunc))
                let confScale: Float = conf >= 2 ? 1 : 0.3
                var sampleWeight = min(8, confScale * 2 / max(surface * surface, 0.04))
                if let left = depthAt(depth, x - 1, y), let right = depthAt(depth, x + 1, y) {
                    let slope = abs(right - left) * 0.5 * params.fx / max(surface, 0.05)
                    if slope > 3.5 { sampleWeight *= 0.25 }
                }
                let previous = slot.pointee.weight
                let blend = previous + sampleWeight
                if previous <= 0.0001 {
                    slot.pointee.sdf = tsdf
                } else {
                    slot.pointee.sdf = (slot.pointee.sdf * previous + tsdf * sampleWeight) / blend
                }
                slot.pointee.weight = min(blend, 48)
            }
        }
    }
}

private enum DepthFilter {
    static func bilateral(_ depth: DepthImage) -> DepthImage {
        guard depth.width > 2, depth.height > 2 else { return depth }
        var output = depth.values
        let width = depth.width
        let height = depth.height
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = depth.values[y * width + x]
                guard center > 0.05 else { continue }
                var sum: Float = 0
                var weight: Float = 0
                for oy in -1...1 {
                    for ox in -1...1 {
                        let sample = depth.values[(y + oy) * width + (x + ox)]
                        guard sample > 0.05 else { continue }
                        let spatial = exp(-Float(ox * ox + oy * oy) * 0.5)
                        let range = exp(-pow(sample - center, 2) / 0.0016)
                        let w = spatial * range
                        sum += sample * w
                        weight += w
                    }
                }
                if weight > 0 { output[y * width + x] = sum / weight }
            }
        }
        return DepthImage(values: output, width: width, height: height)
    }
}

private final class TSDFMetal {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer

    init?(capacity: Int) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeDefaultLibrary(bundle: .main),
              let function = library.makeFunction(name: "integrateTSDF"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let buffer = device.makeBuffer(length: capacity * MemoryLayout<TSDFVoxel>.stride, options: .storageModeShared) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.buffer = buffer
    }

    func reset(_ pointer: UnsafeMutablePointer<TSDFVoxel>, count: Int) {
        buffer.contents().copyMemory(from: UnsafeRawPointer(pointer), byteCount: count * MemoryLayout<TSDFVoxel>.stride)
    }

    func resetBlock(_ index: Int, pointer: UnsafeMutablePointer<TSDFVoxel>) {
        let stride = MemoryLayout<TSDFVoxel>.stride
        let bytes = 512 * stride
        buffer.contents().advanced(by: index * bytes).copyMemory(from: UnsafeRawPointer(pointer.advanced(by: index * 512)), byteCount: bytes)
    }

    func integrate(blocks: [BlockRefCPU], params: TSDFParams, depth: DepthImage, confidence: [UInt8], voxels: UnsafeMutablePointer<TSDFVoxel>) -> Bool {
        guard !blocks.isEmpty,
              let depthTex = makeTexture(width: depth.width, height: depth.height, values: depth.values),
              let confidenceTex = makeConfidence(width: depth.width, height: depth.height, values: confidence),
              let blockBuffer = device.makeBuffer(bytes: blocks, length: MemoryLayout<BlockRefCPU>.stride * blocks.count, options: .storageModeShared),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return false }
        var params = params
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(blockBuffer, offset: 0, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<TSDFParams>.stride, index: 2)
        encoder.setTexture(depthTex, index: 0)
        encoder.setTexture(confidenceTex, index: 1)
        let width = pipeline.threadExecutionWidth
        let threads = MTLSize(width: 512, height: blocks.count, depth: 1)
        let group = MTLSize(width: min(width, 64), height: 1, depth: 1)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: group)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return false }
        let bytes = MemoryLayout<TSDFVoxel>.stride
        for block in blocks {
            let index = Int(block.index)
            let source = buffer.contents().advanced(by: index * 512 * bytes).bindMemory(to: TSDFVoxel.self, capacity: 512)
            voxels.advanced(by: index * 512).assign(from: source, count: 512)
        }
        return true
    }

    private func makeTexture(width: Int, height: Int, values: [Float]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        values.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    private func makeConfidence(width: Int, height: Int, values: [UInt8]) -> MTLTexture? {
        var floats = [Float](repeating: 0, count: width * height)
        for index in 0..<min(values.count, floats.count) {
            floats[index] = Float(values[index])
        }
        return makeTexture(width: width, height: height, values: floats)
    }
}
