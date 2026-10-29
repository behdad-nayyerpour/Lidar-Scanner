import ARKit
import CoreVideo
import simd

struct RGBAImage: Sendable {
    var rgba: [UInt8]
    var width: Int
    var height: Int
    var exposureScale: Float
}

struct DepthImage: Sendable {
    var values: [Float]
    var width: Int
    var height: Int
}

enum PixelSampler {
    static func rgbaImage(from pixelBuffer: CVPixelBuffer, maxDimension: Int, imageResolution: CGSize? = nil) -> RGBAImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sourceWidth = max(1, Int(imageResolution?.width.rounded() ?? CGFloat(bufferWidth)))
        let sourceHeight = max(1, Int(imageResolution?.height.rounded() ?? CGFloat(bufferHeight)))
        guard bufferWidth > 0, bufferHeight > 0 else { return nil }

        let scale = min(1, Float(maxDimension) / Float(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Float(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Float(sourceHeight) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if format == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let sy = min(bufferHeight - 1, y * bufferHeight / height)
                for x in 0..<width {
                    let sx = min(bufferWidth - 1, x * bufferWidth / width)
                    let source = pixels.advanced(by: sy * stride + sx * 4)
                    let dest = (y * width + x) * 4
                    rgba[dest] = source[2]
                    rgba[dest + 1] = source[1]
                    rgba[dest + 2] = source[0]
                    rgba[dest + 3] = 255
                }
            }
            return RGBAImage(rgba: rgba, width: width, height: height, exposureScale: exposureScale(rgba, width: width, height: height))
        }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let yBaseRaw = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBaseRaw = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return nil
        }

        let yBase = yBaseRaw.assumingMemoryBound(to: UInt8.self)
        let uvBase = uvBaseRaw.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        for y in 0..<height {
            let sy = min(bufferHeight - 1, y * bufferHeight / height)
            for x in 0..<width {
                let sx = min(bufferWidth - 1, x * bufferWidth / width)
                let luma = Float(yBase[sy * yStride + sx])
                let uvIndex = (sy / 2) * uvStride + (sx / 2) * 2
                let cb = Float(uvBase[uvIndex])
                let cr = Float(uvBase[uvIndex + 1])
                let yf: Float
                let cbf: Float
                let crf: Float
                if fullRange {
                    yf = luma / 255
                    cbf = (cb - 128) / 255
                    crf = (cr - 128) / 255
                } else {
                    yf = (luma - 16) / 219
                    cbf = (cb - 128) / 224
                    crf = (cr - 128) / 224
                }
                let red = min(1, max(0, yf + 1.402 * crf))
                let green = min(1, max(0, yf - 0.344136 * cbf - 0.714136 * crf))
                let blue = min(1, max(0, yf + 1.772 * cbf))
                let dest = (y * width + x) * 4
                rgba[dest] = UInt8((red * 255).rounded())
                rgba[dest + 1] = UInt8((green * 255).rounded())
                rgba[dest + 2] = UInt8((blue * 255).rounded())
                rgba[dest + 3] = 255
            }
        }
        return RGBAImage(rgba: rgba, width: width, height: height, exposureScale: exposureScale(rgba, width: width, height: height))
    }

    static func depthImage(from depthData: ARDepthData?, maxDimension: Int) -> DepthImage? {
        guard let depthData else { return nil }
        let pixelBuffer = depthData.depthMap
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let scale = min(1, Float(maxDimension) / Float(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Float(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Float(sourceHeight) * scale).rounded()))
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<Float>.size
        let depths = base.assumingMemoryBound(to: Float.self)
        var confidence: UnsafeMutablePointer<UInt8>?
        var confidenceStride = 0
        var confidenceWidth = 0
        var confidenceHeight = 0
        if let confidenceMap = depthData.confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidence = CVPixelBufferGetBaseAddress(confidenceMap)?.assumingMemoryBound(to: UInt8.self)
            confidenceStride = CVPixelBufferGetBytesPerRow(confidenceMap)
            confidenceWidth = CVPixelBufferGetWidth(confidenceMap)
            confidenceHeight = CVPixelBufferGetHeight(confidenceMap)
        }
        defer {
            if let confidenceMap = depthData.confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = min(sourceHeight - 1, y * sourceHeight / height)
            for x in 0..<width {
                let sx = min(sourceWidth - 1, x * sourceWidth / width)
                if let confidence, confidenceStride > 0, confidenceWidth > 0, confidenceHeight > 0 {
                    let cx = min(confidenceWidth - 1, sx * confidenceWidth / sourceWidth)
                    let cy = min(confidenceHeight - 1, sy * confidenceHeight / sourceHeight)
                    if confidence[cy * confidenceStride + cx] == 0 { continue }
                }
                let meters = depths[sy * stride + sx]
                if meters.isFinite, meters > 0.05 {
                    values[y * width + x] = meters
                }
            }
        }
        return DepthImage(values: values, width: width, height: height)
    }

    private static func exposureScale(_ rgba: [UInt8], width: Int, height: Int) -> Float {
        guard width > 0, height > 0 else { return 1 }
        var sum: Float = 0
        var count: Float = 0
        let step = max(1, (width * height) / 4000)
        var index = 0
        while index < width * height {
            let pixel = index * 4
            if pixel + 2 < rgba.count {
                sum += (Float(rgba[pixel]) + Float(rgba[pixel + 1]) + Float(rgba[pixel + 2])) / (3 * 255)
                count += 1
            }
            index += step
        }
        guard count > 0 else { return 1 }
        let mean = sum / count
        guard mean > 0.04 else { return 1 }
        return min(1.2, max(0.82, 0.46 / mean))
    }
}
