import Foundation
import CoreGraphics

// MARK: - サムネイル画像(出力 ▸ サムネイル画像を書き出す…)
//
// 今の再生位置のコマを、1280×720 の画像にする。縦横比が 16:9 でないときは、中に収めて余白を背景色で埋める。
// 形式(PNG / JPEG)は拡張子で決まる。書き出しは静止画と同じ `StillExporter.writeImage`。

public enum ThumbnailExporter {
    public static let width = 1280
    public static let height = 720

    /// 元の大きさを、`canvas` の中に縦横比を保って収めた矩形(中央、小数の画素のまま)。
    public static func fittedRect(source: CGSize, canvas: CGSize = CGSize(width: width, height: height)) -> CGRect {
        guard source.width > 0, source.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let k = min(canvas.width / source.width, canvas.height / source.height)
        let w = source.width * k, h = source.height * k
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }

    /// 1 コマの画像を 1280×720 の不透明な画像にする(余白は `background`、無ければ黒)。
    public static func compose(_ frame: CGImage, background: CGColor?) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(background ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(frame, in: fittedRect(source: CGSize(width: frame.width, height: frame.height)))
        return ctx.makeImage()
    }

    /// 時刻 t のコマを、1280×720 にして書く(PNG / JPEG は `format`)。
    public static func write(project: Project, assets: RenderAssets = RenderAssets(), at t: Double, format: StillFormat, to url: URL) throws {
        guard project.width > 0, project.height > 0 else { throw ExportError.noOutputSize(width: project.width, height: project.height) }
        guard let frame = Renderer(project: project, assets: assets).renderImage(t: t) else { throw ExportError.pixelBufferFailed(-1) }
        guard let thumb = compose(frame, background: parseHexColor(project.bg)) else { throw ExportError.pixelBufferFailed(-1) }
        try StillExporter.writeImage(thumb, format: format, to: url)
    }
}
