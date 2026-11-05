import Foundation

/// 外部から入ってくるファイル(プロジェクト・復元の写し・字幕・フォント・PSD)の上限と、安全な読み込み。
/// 壊れた・悪意のあるファイルで、クラッシュ・固まり・巨大なメモリ確保が起きないようにする。
public enum InputLimits {
    public static let maxProjectBytes = 64 * 1024 * 1024
    public static let maxRecoveryBytes = 96 * 1024 * 1024
    public static let maxSubtitleBytes = 8 * 1024 * 1024
    public static let maxFontBytes = 64 * 1024 * 1024
    public static let maxPSDBytes = 2 * 1024 * 1024 * 1024
    /// JSON の入れ子の深さ(複合クリップの入れ子を含めて十分余裕のある値)。
    public static let maxJSONDepth = 64
    public static let maxTracks = 2_000
    public static let maxClips = 100_000

    public enum Failure: Error, Equatable, LocalizedError {
        case tooLarge(what: String, limit: Int)
        case tooDeep
        case tooMany(String)
        case notRegularFile
        public var errorDescription: String? {
            switch self {
            case .tooLarge(let what, let limit): return "\(what)が大きすぎます(上限 \(limit / 1_048_576) MB)。"
            case .tooDeep: return "ファイルの入れ子が深すぎるので読み込みません。"
            case .tooMany(let what): return "\(what)が多すぎるので読み込みません。"
            case .notRegularFile: return "通常のファイルではないので読み込みません。"
            }
        }
    }

    /// 通常のファイルで、`limit` バイト以下なら中身を読む。シンボリックリンク・特殊ファイル・大きすぎるものは断る。
    public static func readFile(_ url: URL, limit: Int, what: String, allowSymlink: Bool = true) throws -> Data {
        var st = stat()
        guard (allowSymlink ? stat(url.path, &st) : lstat(url.path, &st)) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Failure.notRegularFile }
        guard st.st_size <= Int64(limit) else { throw Failure.tooLarge(what: what, limit: limit) }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw Failure.tooLarge(what: what, limit: limit) }
        return data
    }

    /// JSON の入れ子の深さが上限以内か(文字列の中の括弧は数えない)。パースする前に調べて、再帰で溢れるのを防ぐ。
    public static func jsonDepthWithinLimit(_ data: Data, limit: Int = maxJSONDepth) -> Bool {
        var depth = 0, inString = false, escaped = false
        for b in data {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x22: inString = true
            case 0x5B, 0x7B:
                depth += 1
                if depth > limit { return false }
            case 0x5D, 0x7D: depth = max(0, depth - 1)
            default: break
            }
        }
        return true
    }

    /// 有限でなければ `fallback`、範囲外は端に収める。
    static func clamp(_ v: Double, _ range: ClosedRange<Double>, fallback: Double = 0) -> Double {
        guard v.isFinite else { return fallback }
        return min(max(v, range.lowerBound), range.upperBound)
    }
    static func clampOpt(_ v: Double?, _ range: ClosedRange<Double>) -> Double? {
        guard let v else { return nil }
        guard v.isFinite else { return nil }
        return min(max(v, range.lowerBound), range.upperBound)
    }

    /// 時間(秒)の上限: 100 時間。
    public static let maxSeconds: Double = 360_000
    public static let maxPixelSide = 16_384
}

extension Project {
    /// 読み込んだ直後に、常識外れの数値を安全な範囲に収める(正常な値は 1 ビットも変えない)。
    /// 巨大な長さ・大きさによる巨大なメモリ確保や、無限・非数による描画の破綻を防ぐ。
    mutating func sanitizeLoaded() throws {
        if tracks.count > InputLimits.maxTracks { throw InputLimits.Failure.tooMany("レイヤー") }
        var clipCount = 0
        func count(_ ts: [Track]) throws {
            for t in ts {
                clipCount += t.clips.count
                if clipCount > InputLimits.maxClips { throw InputLimits.Failure.tooMany("クリップ") }
                for c in t.clips { if let sub = c.tracks { try count(sub) } }
            }
        }
        try count(tracks)
        if width < 1 || width > InputLimits.maxPixelSide { width = min(max(width, 1), InputLimits.maxPixelSide) }
        if height < 1 || height > InputLimits.maxPixelSide { height = min(max(height, 1), InputLimits.maxPixelSide) }
        for i in tracks.indices { Self.sanitize(&tracks[i], depth: 0) }
        for i in markers.indices { markers[i].time = InputLimits.clamp(markers[i].time, -InputLimits.maxSeconds...InputLimits.maxSeconds) }
        rangeIn = InputLimits.clampOpt(rangeIn, -InputLimits.maxSeconds...InputLimits.maxSeconds)
        rangeOut = InputLimits.clampOpt(rangeOut, -InputLimits.maxSeconds...InputLimits.maxSeconds)
    }

    private static func sanitize(_ t: inout Track, depth: Int) {
        for i in t.clips.indices {
            var c = t.clips[i]
            let T = -InputLimits.maxSeconds...InputLimits.maxSeconds
            if !(c.start.isFinite && T.contains(c.start)) { c.start = InputLimits.clamp(c.start, T) }
            if !(c.duration.isFinite && T.contains(c.duration)) { c.duration = InputLimits.clamp(c.duration, T) }
            if !(c.offset.isFinite && T.contains(c.offset)) { c.offset = InputLimits.clamp(c.offset, T) }
            func fix(_ v: inout Double?, _ r: ClosedRange<Double>) { if let x = v, !(x.isFinite && r.contains(x)) { v = InputLimits.clampOpt(x, r) } }
            let pos = -1e5...1e5
            fix(&c.srcDuration, T)
            fix(&c.x, pos); fix(&c.y, pos); fix(&c.w, pos); fix(&c.h, pos)
            fix(&c.scale, pos); fix(&c.rotation, -1e6...1e6)
            fix(&c.fontSize, -4000...4000)
            fix(&c.blur, -2000...2000); fix(&c.strength, -2000...2000); fix(&c.mosaicSize, -2000...2000)
            fix(&c.fadeIn, T); fix(&c.fadeOut, T)
            fix(&c.volume, -1000...1000); fix(&c.opacity, -1000...1000); fix(&c.pan, -1000...1000)
            fix(&c.speed, -1000...1000)
            if depth < 8, var sub = c.tracks {
                for j in sub.indices { sanitize(&sub[j], depth: depth + 1) }
                c.tracks = sub
            }
            if c != t.clips[i] { t.clips[i] = c }
        }
    }
}
