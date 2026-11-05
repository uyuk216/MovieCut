import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - APNG の設定

/// アニメーション PNG(APNG)の書き出し設定。GIF と違い 256 色の制限がなく、透明(背景を「透明」にしたとき)も段階のまま残る。
/// 映像は `Renderer`(プレビューと同じ描画経路)で 1 コマずつ描き、`fps` の間隔で取り出す。音は入らない。
public struct APNGOptions: Equatable {
    /// コマ数(1 秒あたり)の範囲。
    public static let fpsRange: ClosedRange<Double> = 1...60
    public static let widthRange: ClosedRange<Int> = GIFOptions.widthRange
    public static let presetFPS: [Double] = [10, 15, 20, 30, 60]
    public static let presetWidths: [Int] = [320, 480, 640, 960]
    /// ループ回数の選択肢(0 = 無限)。
    public static let presetLoops: [Int] = [0, 1, 3]
    public static let loopRange: ClosedRange<Int> = 0...1000

    public var fps: Double
    /// 最大の幅(px)。nil ならプロジェクトの幅のまま。
    public var maxWidth: Int?
    /// 繰り返す回数。0 は無限。
    public var loopCount: Int

    public static let standard = APNGOptions(fps: 15, maxWidth: 480, loopCount: 0)

    public init(fps: Double = 15, maxWidth: Int? = 480, loopCount: Int = 0) {
        self.fps = fps
        self.maxWidth = maxWidth.map { min(max($0, Self.widthRange.lowerBound), Self.widthRange.upperBound) }
        self.loopCount = min(max(loopCount, Self.loopRange.lowerBound), Self.loopRange.upperBound)
    }

    public static func validFPS(_ v: Double) -> Double? { v.isFinite && fpsRange.contains(v) ? v : nil }
}

// MARK: - APNG の書き出し

public enum APNGExporter {
    public struct Result: Equatable {
        public var url: URL
        public var frameCount: Int
        public var width: Int
        public var height: Int
        public var bytes: Int
        public var loopCount: Int
    }

    /// 書き出す前の計画。コマ数は ceil(長さ × fps)、大きさは GIF と同じ決まり。
    public static func plan(project: Project, range: ExportRange?, options: APNGOptions = .standard) -> GIFPlan {
        let (w, h) = GIFExporter.outputSize(project: project, maxWidth: options.maxWidth)
        let duration = range?.duration ?? project.endTime
        let frames = duration > 0 ? max(1, Int(ceil(duration * options.fps - 1e-6))) : 0
        return GIFPlan(width: w, height: h, frames: frames, delay: 1 / options.fps)
    }

    /// `url` に APNG を書く。一時ファイルに書いてから置き換える(キャンセル・失敗では既存のファイルを変えない)。
    /// 各コマの表示時間は ImageIO の APNG 用の項目(`kCGImagePropertyAPNGDelayTime`)で、ループ回数は PNG の辞書(`kCGImagePropertyAPNGLoopCount`)で書く。
    @discardableResult
    public static func export(project: Project, assets: RenderAssets = RenderAssets(), range: ExportRange? = nil,
                              options: APNGOptions = .standard, to url: URL, progress: ((Double) -> Void)? = nil) async throws -> Result {
        let p = plan(project: project, range: range, options: options)
        guard p.frames > 0 else { throw ExportError.emptyProject }
        guard p.width > 0, p.height > 0 else { throw ExportError.noOutputSize(width: project.width, height: project.height) }
        let t0 = range?.start ?? 0
        let fps = options.fps
        let loops = options.loopCount
        let part = url.deletingLastPathComponent().appendingPathComponent(".moviecut-\(UUID().uuidString).png.part")
        let scaled = project.width == p.width ? project : project.scaledForResolution(newWidth: p.width, newHeight: p.height)

        let work = Task.detached(priority: .userInitiated) { () throws -> Result in
            // ImageIO は途中の書きかけを `part` の隣(名前に印が付く)に置くことがあるので、同じ名前で始まるものを全部消す
            func cleanup() { ImageIOPartFiles.remove(part) }
            let renderer = Renderer(project: scaled, assets: assets)
            // dest を手放してから後始末できるよう、描いて書く部分を内側の関数にする
            func write() throws {
            guard let dest = CGImageDestinationCreateWithURL(part as CFURL, UTType.png.identifier as CFString, p.frames, nil) else {
                throw ExportError.cannotCreateWriter(CocoaError(.fileWriteUnknown))
            }
            CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loops]] as CFDictionary)
            assets.beginExportMode()
            defer { assets.endExportMode() }
            var last = -1.0
            for i in 0..<p.frames {
                if Task.isCancelled { cleanup(); throw CancellationError() }
                let frame: CGImage? = autoreleasepool { renderer.renderImage(t: t0 + Double(i) / fps) }
                guard let img = frame else { cleanup(); throw ExportError.pixelBufferFailed(-1) }
                CGImageDestinationAddImage(dest, img, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: p.delay]] as CFDictionary)
                let v = Double(i + 1) / Double(p.frames)
                if v - last >= 0.001 || i + 1 == p.frames { last = v; progress?(v) }
            }
            if Task.isCancelled { cleanup(); throw CancellationError() }
            guard CGImageDestinationFinalize(dest) else { throw ExportError.writerFailed(nil) }
            }
            do { try write() } catch { cleanup(); throw error }
            if Task.isCancelled { cleanup(); throw CancellationError() }
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: part, to: url)
            } catch {
                cleanup()
                throw ExportError.cannotCreateWriter(error)
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return Result(url: url, frameCount: p.frames, width: p.width, height: p.height, bytes: bytes, loopCount: loops)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

/// ImageIO の書きかけファイルの後始末(`part` と、ImageIO が `part` の名前に印を足して隣に作るファイルを消す)。
enum ImageIOPartFiles {
    static func remove(_ part: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: part)
        let dir = part.deletingLastPathComponent()
        let prefix = part.lastPathComponent
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.contains(prefix) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
