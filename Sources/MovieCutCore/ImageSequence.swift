import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 連番画像の取り込み(#6)
//
// frame_0001.png のような連番画像を 1 つのアニメーション素材として取り込む。
// 取り込み時に APNG(アニメーション PNG)へまとめ、画像クリップには「アニメーションを再生する」
// 印(`Clip.playsAnimation`)を付ける。描画側は既存のアニメーション画像の仕組み
// (`AnimatedImage` / `RenderAssets.animatedImage(at:elapsed:)`)でコマを選ぶので、
// 静止画クリップの従来の描画経路は変えない。APNG は透明も残り、素材が 1 ファイルになるため
// パッケージ保存・再リンクの扱いも通常の画像と同じになる。

/// 連番のファイル名の分解結果。
public struct SequenceFileName: Equatable, Sendable {
    /// 数字の前の部分(例 "frame_")。
    public var prefix: String
    /// 数字の後の部分(拡張子を除く。例 "_mask" や "")。
    public var suffix: String
    /// 番号。
    public var number: Int
    /// 数字の桁数(ゼロ埋めの幅)。
    public var digits: Int
    /// 拡張子(小文字、ピリオドなし)。
    public var ext: String

    public init(prefix: String, suffix: String, number: Int, digits: Int, ext: String) {
        self.prefix = prefix; self.suffix = suffix; self.number = number; self.digits = digits; self.ext = ext
    }
}

/// 連番画像のまとまり(同じフォルダ・同じ接頭辞・同じ拡張子・同じ桁数)。
public struct ImageSequence: Equatable, Sendable {
    /// コマ 1 枚。
    public struct Frame: Equatable, Sendable {
        public var path: String
        public var number: Int
        public init(path: String, number: Int) { self.path = path; self.number = number }
    }

    public var directory: String
    public var prefix: String
    public var suffix: String
    public var ext: String
    public var digits: Int
    /// 番号の昇順に並んだコマ。
    public var frames: [Frame]
    /// 抜けている番号(最小〜最大の間で、コマが無いもの)。
    public var missingNumbers: [Int]

    public var frameCount: Int { frames.count }
    /// 表示名(例 "frame_ (12 コマ)")。
    public var displayName: String { "\(prefix.isEmpty ? "(番号)" : prefix) (\(frames.count) コマ)" }

    /// フレームレート `fps` で再生したときの長さ(秒)。
    public func duration(fps: Double) -> Double {
        Double(frames.count) / ImageSequence.validFPS(fps)
    }

    /// フレームレートの範囲(1〜60)と丸め。
    public static let fpsRange: ClosedRange<Double> = 1...60
    public static let defaultFPS = 24.0
    public static func validFPS(_ v: Double) -> Double {
        v.isFinite ? min(max(v, fpsRange.lowerBound), fpsRange.upperBound) : defaultFPS
    }
}

public enum ImageSequenceDetector {
    /// 欠番として列挙する上限(これ以上抜けていても、列挙はここで打ち切る)。
    public static let missingLimit = 10_000
    /// 連番として扱う対象の拡張子(画像クリップと同じ)。
    public static func isSequenceCandidate(path: String) -> Bool {
        ClipEditing.imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// ファイル名を分解する: 拡張子を除いた名前の中の「最後の数字の並び」を番号とする。
    /// 数字が無ければ nil。
    public static func parseFileName(_ name: String) -> SequenceFileName? {
        let ext = (name as NSString).pathExtension.lowercased()
        let stem = (name as NSString).deletingPathExtension
        // 最後の数字の並びを探す
        var end: Int? = nil
        var start: Int? = nil
        let chars = Array(stem)
        var i = chars.count - 1
        while i >= 0 {
            if chars[i].isNumber {
                if end == nil { end = i }
                start = i
                i -= 1
            } else if end != nil {
                break
            } else {
                i -= 1
            }
        }
        guard let s = start, let e = end, let number = Int(String(chars[s...e])) else { return nil }
        return SequenceFileName(prefix: String(chars[..<s]), suffix: String(chars[(e + 1)...]),
                                number: number, digits: e - s + 1, ext: ext)
    }

    /// ファイルパスの列から連番のまとまりを見つける(2 コマ以上で、番号が重ならないもの)。
    /// 戻り値は (フォルダ, 接頭辞) の順に安定させる。
    public static func detect(urls: [URL]) -> [ImageSequence] {
        struct GroupKey: Hashable { var directory, prefix, suffix, ext: String; var digits: Int }
        var groups: [GroupKey: [ImageSequence.Frame]] = [:]
        for url in urls where isSequenceCandidate(path: url.path) {
            guard let parsed = parseFileName(url.lastPathComponent) else { continue }
            let key = GroupKey(directory: url.deletingLastPathComponent().path, prefix: parsed.prefix,
                               suffix: parsed.suffix, ext: parsed.ext, digits: parsed.digits)
            groups[key, default: []].append(ImageSequence.Frame(path: url.path, number: parsed.number))
        }
        var out: [ImageSequence] = []
        for (key, frames) in groups {
            let sorted = frames.sorted { $0.number < $1.number }
            // 同じ番号が重なるまとまりは連番として扱わない
            guard sorted.count >= 2, Set(sorted.map(\.number)).count == sorted.count else { continue }
            // 欠番は隣り合う番号の間だけを数え、上限までで打ち切る。
            // (最小〜最大の範囲を全走査すると、1 と 100000000 のような疎な巨大番号で
            //  範囲そのものが爆発して固まる・メモリを食い尽くすため。F-4 の対策)
            var missing: [Int] = []
            for i in 1..<sorted.count {
                var n = sorted[i - 1].number + 1
                while n < sorted[i].number, missing.count < missingLimit {
                    missing.append(n)
                    n += 1
                }
                if missing.count >= missingLimit { break }
            }
            out.append(ImageSequence(directory: key.directory, prefix: key.prefix, suffix: key.suffix,
                                     ext: key.ext, digits: key.digits, frames: sorted, missingNumbers: missing))
        }
        return out.sorted { ($0.directory, $0.prefix, $0.suffix) < ($1.directory, $1.prefix, $1.suffix) }
    }

    /// フォルダ直下のファイルから連番を見つける(隠しファイルは除く)。
    public static func detectInFolder(_ folder: URL) -> [ImageSequence] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let urls = names.filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }
        return detect(urls: urls)
    }

    /// パスの列が 1 つの連番として取り込めるか(まとまりが 1 つだけ見つかり、その全コマが含まれるとき、その連番)。
    public static func singleSequence(urls: [URL]) -> ImageSequence? {
        let found = detect(urls: urls)
        guard found.count == 1, let seq = found.first else { return nil }
        let wanted = Set(seq.frames.map(\.path))
        let given = Set(urls.map(\.path))
        return wanted == given ? seq : nil
    }
}

public enum ImageSequenceError: Error, Equatable, CustomStringConvertible {
    case noFrames
    case unreadableFrame(String)
    case writeFailed

    public var description: String {
        switch self {
        case .noFrames: return "コマがありません"
        case .unreadableFrame(let name): return "コマを読めませんでした: \(name)"
        case .writeFailed: return "アニメーション PNG を作れませんでした"
        }
    }
}

public enum ImageSequenceImporter {
    /// キャッシュフォルダの名前(全コマのパス + 最初のコマの更新日時・サイズ + fps から。PSD と同じ決め方)。
    public static func cacheKey(sequence: ImageSequence, fps: Double) -> String {
        let first = sequence.frames.first?.path ?? ""
        let attrs = try? FileManager.default.attributesOfItem(atPath: first)
        let base = PSDImporter.cacheKey(path: sequence.frames.map(\.path).joined(separator: "|"),
                                        modified: attrs?[.modificationDate] as? Date,
                                        size: (attrs?[.size] as? NSNumber)?.int64Value)
        return base + "-\(sequence.frameCount)f-\(Int(ImageSequence.validFPS(fps)))fps"
    }

    /// コマを 1 枚の画像として読む(読めなければ nil)。
    static func frameImage(_ path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return img
    }

    /// 連番を APNG にまとめて `url` へ書く。各コマの表示時間は 1/fps、ループは無限。
    /// コマの大きさが違うときは、最初のコマの大きさのキャンバスに収めて描く(縦横比は保つ)。
    public static func writeAPNG(sequence: ImageSequence, fps: Double, to url: URL) throws {
        guard !sequence.frames.isEmpty else { throw ImageSequenceError.noFrames }
        guard let first = frameImage(sequence.frames[0].path) else {
            throw ImageSequenceError.unreadableFrame((sequence.frames[0].path as NSString).lastPathComponent)
        }
        let w = first.width, h = first.height
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = url.deletingLastPathComponent().appendingPathComponent(".moviecut-\(UUID().uuidString).png.part")
        guard let dest = CGImageDestinationCreateWithURL(part as CFURL, UTType.png.identifier as CFString, sequence.frames.count, nil) else {
            throw ImageSequenceError.writeFailed
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        let delay = 1 / ImageSequence.validFPS(fps)
        for frame in sequence.frames {
            guard let img = frameImage(frame.path) else {
                try? fm.removeItem(at: part)
                throw ImageSequenceError.unreadableFrame((frame.path as NSString).lastPathComponent)
            }
            let props = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay]] as CFDictionary
            if img.width == w, img.height == h {
                CGImageDestinationAddImage(dest, img, props)
            } else {
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    try? fm.removeItem(at: part)
                    throw ImageSequenceError.writeFailed
                }
                let fit = min(Double(w) / Double(img.width), Double(h) / Double(img.height))
                let dw = Double(img.width) * fit, dh = Double(img.height) * fit
                ctx.draw(img, in: CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh))
                guard let fitted = ctx.makeImage() else {
                    try? fm.removeItem(at: part)
                    throw ImageSequenceError.writeFailed
                }
                CGImageDestinationAddImage(dest, fitted, props)
            }
        }
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: part)
            throw ImageSequenceError.writeFailed
        }
        try? fm.removeItem(at: url)
        try fm.moveItem(at: part, to: url)
    }

    /// 連番を APNG にまとめて `cacheDir` へ書き、そのパスを返す。すでにあれば作り直さない。
    @discardableResult
    public static func prepare(sequence: ImageSequence, fps: Double, cacheDir: URL) throws -> String {
        let url = cacheDir.appendingPathComponent("sequence.png")
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path), (a[.size] as? NSNumber)?.intValue ?? 0 > 0 {
            return url.path
        }
        try writeAPNG(sequence: sequence, fps: fps, to: url)
        return url.path
    }

    /// APNG 化した連番を、アニメーション再生する画像クリップとして置く。長さはコマ数 ÷ fps。
    /// 置いたクリップの id を返す。
    @discardableResult
    public static func place(apngPath: String, sequence: ImageSequence, fps: Double, at start: Double,
                             in project: inout Project) -> [String] {
        let clip = makeClip(apngPath: apngPath, sequence: sequence, fps: fps, start: start)
        if project.tracks.isEmpty { project.tracks.append(Track(name: "レイヤー1")) }
        let ti: Int
        if let free = ClipEditing.freeTrack(in: project, start: start, duration: clip.duration) {
            ti = free
        } else {
            project.tracks.append(Track(name: "レイヤー\(project.tracks.count + 1)"))
            ti = project.tracks.count - 1
        }
        project.tracks[ti].clips.append(clip)
        return [clip.id]
    }

    /// 連番の画像クリップ(アニメーション再生の印つき)。
    public static func makeClip(apngPath: String, sequence: ImageSequence, fps: Double, start: Double) -> Clip {
        var clip = ClipEditing.makeMediaClip(path: apngPath, kind: .image, duration: sequence.duration(fps: fps), start: start)
        clip.playsAnimation = true
        return clip
    }
}
