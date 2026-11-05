import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - GIF の設定

/// アニメーション GIF の書き出し設定。
/// 映像は `Renderer`(プレビューと同じ描画経路)で 1 コマずつ描き、`fps` の間隔で取り出す。音は入らない。
public struct GIFOptions: Equatable {
    /// コマ数(1 秒あたり)の範囲。GIF は 1/100 秒単位で時間を持つので、30 fps 超は意味が薄い。
    public static let fpsRange: ClosedRange<Double> = 1...30
    /// 最大の幅(px)の範囲。
    public static let widthRange: ClosedRange<Int> = 16...4096
    /// メニューの定番の fps と幅。
    public static let presetFPS: [Double] = [5, 10, 15, 20, 30]
    public static let presetWidths: [Int] = [320, 480, 640]

    public var fps: Double
    /// 最大の幅(px)。プロジェクトより大きくはしない。nil ならプロジェクトの幅のまま。高さは縦横比で決める。
    public var maxWidth: Int?

    /// 既定: 10 fps・幅 480px。
    public static let standard = GIFOptions(fps: 10, maxWidth: 480)

    public init(fps: Double = 10, maxWidth: Int? = 480) {
        self.fps = fps
        self.maxWidth = maxWidth.map { min(max($0, Self.widthRange.lowerBound), Self.widthRange.upperBound) }
    }

    /// fps を検証する(範囲外・有限でない値は nil)。
    public static func validFPS(_ v: Double) -> Double? {
        v.isFinite && fpsRange.contains(v) ? v : nil
    }
}

/// 書き出す前の計画(コマ数・出力サイズ・1 コマの時間)。シートの表示とテストに使う。
public struct GIFPlan: Equatable {
    public var width: Int
    public var height: Int
    public var frames: Int
    /// 1 コマの表示時間(秒)。GIF は 1/100 秒で書くので、実際の表示時間は ImageIO が丸める。
    public var delay: Double
}

// MARK: - GIF の書き出し

public enum GIFExporter {
    public struct Result: Equatable {
        public var url: URL
        public var frameCount: Int
        public var width: Int
        public var height: Int
        public var bytes: Int
    }

    /// 範囲(nil なら全体)・設定から計画を立てる。コマ数は ceil(長さ × fps)。
    public static func plan(project: Project, range: ExportRange?, options: GIFOptions = .standard) -> GIFPlan {
        let (w, h) = outputSize(project: project, maxWidth: options.maxWidth)
        let duration = range?.duration ?? project.endTime
        let frames = duration > 0 ? max(1, Int(ceil(duration * options.fps - 1e-6))) : 0
        return GIFPlan(width: w, height: h, frames: frames, delay: 1 / options.fps)
    }

    /// 出力サイズ。プロジェクトより大きくはしない(幅を縮める)。高さは縦横比のまま、1 以上に丸める。
    public static func outputSize(project: Project, maxWidth: Int?) -> (width: Int, height: Int) {
        guard project.width > 0, project.height > 0 else { return (0, 0) }
        guard let mw = maxWidth, mw < project.width else { return (project.width, project.height) }
        let w = max(GIFOptions.widthRange.lowerBound, mw)
        let h = max(1, Int((Double(project.height) * Double(w) / Double(project.width)).rounded()))
        return (w, h)
    }

    /// `url` に GIF を書く(無限ループ)。途中のファイルは `url` の隣の一時ファイルに書き、終わってから置き換える。
    /// キャンセル・失敗のときは一時ファイルを消し、既存の `url` は変えない。進み具合は 0〜1。
    @discardableResult
    public static func export(project: Project, assets: RenderAssets = RenderAssets(), range: ExportRange? = nil,
                              options: GIFOptions = .standard, to url: URL, progress: ((Double) -> Void)? = nil) async throws -> Result {
        let p = plan(project: project, range: range, options: options)
        guard p.frames > 0 else { throw ExportError.emptyProject }
        guard p.width > 0, p.height > 0 else { throw ExportError.noOutputSize(width: project.width, height: project.height) }
        let t0 = range?.start ?? 0
        let fps = options.fps
        let part = url.deletingLastPathComponent().appendingPathComponent(".moviecut-\(UUID().uuidString).gif.part")
        let scaled = project.width == p.width ? project : project.scaledForResolution(newWidth: p.width, newHeight: p.height)

        let work = Task.detached(priority: .userInitiated) { () throws -> Result in
            // ImageIO は途中の書きかけを `part` の隣(名前に印が付く)に置くことがあるので、同じ名前で始まるものを全部消す
            func cleanup() { ImageIOPartFiles.remove(part) }
            let renderer = Renderer(project: scaled, assets: assets)
            // dest を手放してから後始末できるよう、描いて書く部分を内側の関数にする
            func write() throws {
            guard let dest = CGImageDestinationCreateWithURL(part as CFURL, UTType.gif.identifier as CFString, p.frames, nil) else {
                throw ExportError.cannotCreateWriter(CocoaError(.fileWriteUnknown))
            }
            // 0 は無限ループ
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            assets.beginExportMode()
            defer { assets.endExportMode() }
            var last = -1.0
            for i in 0..<p.frames {
                if Task.isCancelled { cleanup(); throw CancellationError() }
                let frame: CGImage? = autoreleasepool { renderer.renderImage(t: t0 + Double(i) / fps) }
                guard let img = frame else { cleanup(); throw ExportError.pixelBufferFailed(-1) }
                CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: p.delay]] as CFDictionary)
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
            return Result(url: url, frameCount: p.frames, width: p.width, height: p.height, bytes: bytes)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
