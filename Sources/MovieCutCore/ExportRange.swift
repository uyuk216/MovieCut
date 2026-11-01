import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 書き出し範囲

/// 書き出す区間(秒)。タイムラインのイン点・アウト点から決まる。`start < end` で、0 以上、プロジェクトの終わり以下。
public struct ExportRange: Equatable {
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }

    /// これより短い範囲は作らない(秒)。
    public static let minLength = 0.001

    public init(start: Double, end: Double) { self.start = start; self.end = end }

    /// イン点・アウト点(どちらか欠けていてもよい)から範囲を決める。イン点が無ければ 0、アウト点が無ければ終わり。
    /// プロジェクトの外は切り詰める。長さが無い(逆転・同じ)ときは nil。
    public static func resolve(rangeIn: Double?, rangeOut: Double?, endTime: Double) -> ExportRange? {
        guard rangeIn != nil || rangeOut != nil, endTime > 0 else { return nil }
        let a = min(max(0, rangeIn ?? 0), endTime)
        let b = min(max(0, rangeOut ?? endTime), endTime)
        return b - a >= minLength ? ExportRange(start: a, end: b) : nil
    }

    /// コマンドラインの `a:b`(秒。どちらかを省いてよい: `2:` は 2 秒から終わりまで、`:5` は頭から 5 秒まで)。
    public static func parse(_ text: String, endTime: Double) -> Result<ExportRange, InputError> {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return .failure(InputError(message: "範囲は 開始:終了(秒)の形で指定してください。例 2:4.5")) }
        func num(_ s: String) -> Double?? {
            if s.isEmpty { return .some(nil) }
            guard let v = Double(s), v.isFinite, v >= 0 else { return nil }
            return .some(v)
        }
        guard let a = num(parts[0]), let b = num(parts[1]) else { return .failure(InputError(message: "範囲の秒数は 0 以上の数字で指定してください。例 2:4.5")) }
        if a == nil && b == nil { return .failure(InputError(message: "範囲の開始か終了のどちらかは指定してください。例 2:4.5")) }
        guard let r = resolve(rangeIn: a, rangeOut: b, endTime: endTime) else {
            return .failure(InputError(message: "範囲が空です(プロジェクトは \(String(format: "%.3f", endTime)) 秒まで)。開始 < 終了にしてください"))
        }
        return .success(r)
    }

    /// 範囲の中のコマ数(= ceil(長さ × fps))。
    public func frameCount(_ rate: FrameRate) -> Int { rate.frameCount(duration: duration) }
    /// 範囲の i コマ目のタイムライン上の時刻。
    public func time(ofFrame i: Int, _ rate: FrameRate) -> Double { start + rate.time(ofFrame: i) }
}

public extension Project {
    /// 設定されている書き出し範囲(イン/アウトのどちらも無い、または空なら nil)。
    var exportRange: ExportRange? { ExportRange.resolve(rangeIn: rangeIn, rangeOut: rangeOut, endTime: endTime) }
}

/// 出力 ▸ 書き出し開始を現在位置に / 終了を現在位置に / 範囲を解除。純粋な計算(モデルは結果が変わったときだけ Undo に載せる)。
public enum ExportRangeEditing {
    /// イン点を t にする。t がアウト点以降なら nil(変えない)。
    public static func settingIn(_ p: Project, at t: Double) -> Project? {
        guard p.endTime > 0 else { return nil }
        let v = min(max(0, t), p.endTime)
        if let o = p.rangeOut, o <= p.endTime, o - v < ExportRange.minLength { return nil }   // 終わりより後ろの古い印は無視
        if v >= p.endTime - ExportRange.minLength { return nil }
        var q = p; q.rangeIn = v
        return q
    }

    /// アウト点を t にする。t がイン点以前なら nil。
    public static func settingOut(_ p: Project, at t: Double) -> Project? {
        guard p.endTime > 0 else { return nil }
        let v = min(max(0, t), p.endTime)
        if let i = p.rangeIn, i < p.endTime, v - i < ExportRange.minLength { return nil }
        if v < ExportRange.minLength { return nil }
        var q = p; q.rangeOut = v
        return q
    }

    public static func clearing(_ p: Project) -> Project {
        var q = p; q.rangeIn = nil; q.rangeOut = nil
        return q
    }
}

// MARK: - 画像の形式と連番の名前

public enum StillFormat: String, CaseIterable {
    case png, jpeg

    public var fileExtension: String { self == .png ? "png" : "jpg" }
    public var title: String { self == .png ? "PNG" : "JPEG" }
    var utType: UTType { self == .png ? .png : .jpeg }

    public init?(cliName: String) {
        switch cliName.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        default: return nil
        }
    }

    public init?(pathExtension: String) { self.init(cliName: pathExtension) }
}

public enum ImageSequenceNaming {
    /// 連番の桁数(最低 5。コマ数が 99999 を超えるなら足りるだけ)。
    public static func digits(frameCount n: Int) -> Int { max(5, String(max(1, n)).count) }

    /// `name_00001.png`(番号は 1 から)。
    public static func fileName(base: String, index: Int, digits: Int, format: StillFormat) -> String {
        let num = String(index)
        return base + "_" + String(repeating: "0", count: max(0, digits - num.count)) + num + "." + format.fileExtension
    }
}

// MARK: - 静止画・連番画像の書き出し

public enum StillExporter {
    public static let jpegQuality = 0.92

    /// 1 コマを描いて、PNG / JPEG で書く(プロジェクトの解像度・ビューアと同じ `Renderer`)。
    public static func write(project: Project, assets: RenderAssets = RenderAssets(), at t: Double, format: StillFormat, to url: URL) throws {
        guard project.width > 0, project.height > 0 else { throw ExportError.noOutputSize(width: project.width, height: project.height) }
        let renderer = Renderer(project: project, assets: assets)
        guard let img = renderer.renderImage(t: t) else { throw ExportError.pixelBufferFailed(-1) }
        try writeImage(img, format: format, to: url)
    }

    public static func writeImage(_ img: CGImage, format: StillFormat, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw ExportError.cannotCreateWriter(CocoaError(.fileWriteUnknown))
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writerFailed(nil) }
    }
}

public enum ImageSequenceExporter {
    public struct Result: Equatable {
        public var directory: URL
        public var frameCount: Int
        public var files: [String]
    }

    /// 連番の計画(コマ数・桁数・最初と最後の名前)。書き出す前に見せるのと、テストに使う。
    public static func plan(project: Project, range: ExportRange?, base: String, format: StillFormat) -> (frames: Int, digits: Int, first: String, last: String) {
        let n = project.frameRate.frameCount(duration: range?.duration ?? project.endTime)
        let d = ImageSequenceNaming.digits(frameCount: n)
        return (n, d, ImageSequenceNaming.fileName(base: base, index: 1, digits: d, format: format),
                ImageSequenceNaming.fileName(base: base, index: max(1, n), digits: d, format: format))
    }

    /// `directory` に `base_00001.png` … を書く。キャンセルされたら、そこまでに書いたファイルを消して CancellationError。
    /// 進み具合は 0〜1。ディレクトリが無ければ作る。
    @discardableResult
    public static func export(project: Project, assets: RenderAssets = RenderAssets(), range: ExportRange? = nil, to directory: URL,
                              base: String, format: StillFormat, progress: ((Double) -> Void)? = nil) async throws -> Result {
        let p = plan(project: project, range: range, base: base, format: format)
        guard p.frames > 0 else { throw ExportError.emptyProject }
        guard project.width > 0, project.height > 0 else { throw ExportError.noOutputSize(width: project.width, height: project.height) }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw ExportError.cannotCreateWriter(error) }
        let rate = project.frameRate
        let t0 = range?.start ?? 0
        let work = Task.detached(priority: .userInitiated) { () throws -> Result in
            let renderer = Renderer(project: project, assets: assets)
            assets.beginExportMode()
            defer { assets.endExportMode() }
            var written: [String] = []
            func cleanup() { for f in written { try? FileManager.default.removeItem(at: directory.appendingPathComponent(f)) } }
            var last = -1.0
            for i in 0..<p.frames {
                if Task.isCancelled { cleanup(); throw CancellationError() }
                let name = ImageSequenceNaming.fileName(base: base, index: i + 1, digits: p.digits, format: format)
                do {
                    try autoreleasepool {
                        guard let img = renderer.renderImage(t: t0 + rate.time(ofFrame: i)) else { throw ExportError.pixelBufferFailed(-1) }
                        try StillExporter.writeImage(img, format: format, to: directory.appendingPathComponent(name))
                    }
                } catch { cleanup(); throw error }
                written.append(name)
                let v = Double(i + 1) / Double(p.frames)
                if v - last >= 0.001 || i + 1 == p.frames { last = v; progress?(v) }
            }
            return Result(directory: directory, frameCount: written.count, files: written)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

/// 範囲ループ再生の時刻の決め方(純粋な計算)。
public enum ExportRangeLoop {
    /// 再生を始める時刻: 範囲の外(頭より前・終わり以降)にいたら範囲の頭、範囲の中ならそのまま。
    public static func startTime(current t: Double, range r: ExportRange) -> Double {
        (t < r.start || t >= r.end - 1e-6) ? r.start : t
    }

    /// 再生中の時刻 t が範囲の終わりに届いたら、戻す先(範囲の頭)。まだなら nil。
    public static func wrap(_ t: Double, range r: ExportRange) -> Double? {
        t >= r.end ? r.start : nil
    }
}
