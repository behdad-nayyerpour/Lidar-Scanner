import CoreVideo
import simd

struct RGBAImage: Sendable {
    var rgba: [UInt8]
    var width: Int
    var height: Int
}

enum PixelSampler {
    static func rgbaImage(from pixelBuffer: CVPixelBuffer, maxDimension: Int) -> RGBAImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(1, Float(maxDimension) / Float(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Float(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Float(sourceHeight) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if format == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let sy = min(sourceHeight - 1, y * sourceHeight / height)
                for x in 0..<width {
                    let sx = min(sourceWidth - 1, x * sourceWidth / width)
                    let source = pixels.advanced(by: sy * stride + sx * 4)
                    let dest = (y * width + x) * 4
                    rgba[dest] = source[2]
                    rgba[dest + 1] = source[1]
                    rgba[dest + 2] = source[0]
                    rgba[dest + 3] = 255
                }
            }
            return RGBAImage(rgba: rgba, width: width, height: height)
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
            let sy = min(sourceHeight - 1, y * sourceHeight / height)
            for x in 0..<width {
                let sx = min(sourceWidth - 1, x * sourceWidth / width)
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
        return RGBAImage(rgba: rgba, width: width, height: height)
    }
}
