import Foundation
import CoreGraphics
import CoreImage
import Vision
import ImageIO
import UniformTypeIdentifiers

/// 静止画の背景を抜く(前景のマスクでアルファを作る)。検出器は差し替えられる(テストは固定マスクを渡す)。
public protocol ForegroundMaskDetecting {
    /// 前景が白・背景が黒のマスク(画像と同じ大きさ)。前景が見つからなければ nil。
    func foregroundMask(for image: CGImage) throws -> CGImage?
}

public enum ForegroundCutoutError: Error, Equatable {
    case noForeground
    case unreadableImage(String)
    case writeFailed(String)
}

/// Vision の前景インスタンスマスク(macOS 14 以降)による検出器。
public struct VisionForegroundDetector: ForegroundMaskDetecting {
    public init() {}

    public func foregroundMask(for image: CGImage) throws -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        let ci = CIImage(cvPixelBuffer: buffer)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(ci, from: ci.extent)
    }
}

public enum ForegroundCutout {
    /// 画像の背景を抜く。マスクの白い所を残し、黒い所を透明にする(RGBA)。前景が無ければ `noForeground`。
    /// マスクが画像と大きさが違うときは、マスクを画像の大きさに引き伸ばして使う。
    public static func cutout(_ image: CGImage, detector: ForegroundMaskDetecting) throws -> CGImage {
        guard let mask = try detector.foregroundMask(for: image) else { throw ForegroundCutoutError.noForeground }
        let ci = CIImage(cgImage: image)
        let m = CIImage(cgImage: mask)
        let sx = ci.extent.width / m.extent.width
        let sy = ci.extent.height / m.extent.height
        let maskScaled = m.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        guard let blend = CIFilter(name: "CIBlendWithMask") else { throw ForegroundCutoutError.noForeground }
        blend.setValue(ci, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskScaled, forKey: kCIInputMaskImageKey)
        guard let out = blend.outputImage else { throw ForegroundCutoutError.noForeground }
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        guard let cg = ctx.createCGImage(out, from: ci.extent) else { throw ForegroundCutoutError.noForeground }
        return cg
    }

    /// 透明を保つ PNG として書く(親フォルダは作る)。
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ForegroundCutoutError.writeFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ForegroundCutoutError.writeFailed(url.lastPathComponent) }
    }

    /// 静止画を読む(失敗は `unreadableImage`)。
    public static func readImage(at url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ForegroundCutoutError.unreadableImage(url.lastPathComponent)
        }
        return img
    }
}
