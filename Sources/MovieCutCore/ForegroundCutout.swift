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

// MARK: - オブジェクトマスク用の前景インスタンス検出

/// 前景の 1 インスタンス(人物・物体 1 つ分)。マスクは画像全体の大きさで、白 = その対象。
public struct ForegroundInstance {
    /// 対象の外接矩形(画像に対する割合・左上原点)。マスクの白い画素から測る。
    public var rect: TrackRect
    /// 画像全体の大きさのグレースケールマスク(白 = 対象)。
    public var mask: CGImage

    public init(rect: TrackRect, mask: CGImage) { self.rect = rect; self.mask = mask }
}

/// 前景インスタンスの一覧を返す検出器。テストでは固定のインスタンスを渡す偽物に差し替える。
public protocol ForegroundInstanceDetecting {
    func instances(for image: CGImage) throws -> [ForegroundInstance]
}

/// Vision の前景インスタンスマスクによる検出器(オブジェクトマスクの種取り)。
/// インスタンスごとにマスクを作り直し、白い画素の外接矩形を対象の矩形とする。
public struct VisionForegroundInstanceDetector: ForegroundInstanceDetecting {
    public init() {}

    public func instances(for image: CGImage) throws -> [ForegroundInstance] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return [] }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        var out: [ForegroundInstance] = []
        for index in result.allInstances {
            let buffer = try result.generateScaledMaskForImage(forInstances: [index], from: handler)
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let cg = ctx.createCGImage(ci, from: ci.extent),
                  let rect = ObjectMaskImage.boundingRect(ofMask: cg) else { continue }
            out.append(ForegroundInstance(rect: rect, mask: cg))
        }
        return out
    }
}

// MARK: - 人物セグメンテーション(クリック不要の自動人物抜き)

/// Vision の人物セグメンテーション(`VNGeneratePersonSegmentationRequest`、品質バランス型)による検出器。
/// 画面内の人物すべてを 1 つのマスクにまとめ、1 つのインスタンスとして返す(人物が居なければ空)。
/// 種マスクの輪郭の時間追従は、前景インスタンスと同じ矩形追跡(`ObjectTracking`)に乗せる。
public struct VisionPersonSegmentationDetector: ForegroundInstanceDetecting {
    public init() {}

    public func instances(for image: CGImage) throws -> [ForegroundInstance] {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return [] }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return PersonMaskInstance.make(from: CIImage(cvPixelBuffer: buffer), imageSize: CGSize(width: image.width, height: image.height), context: ctx)
    }
}

public enum PersonMaskInstance {
    /// 人物マスク(白 = 人物)を画像と同じ大きさへ引き伸ばし、グレースケールの 1 インスタンスにする。
    /// 白い画素が無ければ空配列。Vision とは独立の純粋な後処理(合成マスクでテストできる)。
    public static func make(from mask: CIImage, imageSize: CGSize, context: CIContext) -> [ForegroundInstance] {
        let ext = mask.extent
        guard ext.width >= 1, ext.height >= 1, imageSize.width >= 1, imageSize.height >= 1 else { return [] }
        let scaled = mask
            .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: imageSize.width / ext.width, y: imageSize.height / ext.height))
        guard let gray = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let cg = context.createCGImage(scaled, from: CGRect(origin: .zero, size: imageSize), format: .L8, colorSpace: gray),
              let rect = ObjectMaskImage.boundingRectUpright(ofMask: cg) else { return [] }
        return [ForegroundInstance(rect: rect, mask: cg)]
    }
}
