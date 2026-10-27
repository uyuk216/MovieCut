import Foundation
import AVFoundation

/// タイムライン編集の純粋な計算(UI にも Undo にも依存しない)。renderer.js の snapTime / startDrag /
/// splitAtPlayhead / deleteSelected / addMedia / btn-text / btn-blur と同じ振る舞いを、Project の値として扱う。
///
/// ドラッグ系(move / trimLeft / trimRight)は「ドラッグ開始時のプロジェクト(スナップショット)」を受け取り、
/// そこから dt だけ動かした新しいプロジェクトを返す。毎回スナップショットから作り直すので、
/// 動かして戻すとぴったり元に戻り、途中経過が積み重なって誤差が出ることもない。
public enum ClipEditing {
    /// これより短いクリップにはしない(秒)。
    public static let minDuration = 0.05
    /// 吸着が効く距離(ビューの pt)。
    public static let snapThresholdPoints = 8.0
    /// 画像を置くときの長さ(秒)。測れなかったときの長さにも使う。
    public static let defaultMediaDuration = 5.0

    /// 編集結果。`guides` は吸着が効いた時刻(吸着の案内線の位置)。
    public struct Result: Equatable {
        public var project: Project
        public var guides: [Double]
    }

    // MARK: 吸着

    /// 吸着の候補: 0、再生ヘッド、`excluding` 以外の全クリップの頭と終わり。
    static func snapCandidates(excluding id: String?, project: Project, playhead: Double) -> [Double] {
        var pts = [0, playhead]
        for c in project.allClips where c.id != id { pts.append(c.start); pts.append(c.start + c.duration) }
        return pts
    }

    /// `time` の近く(8pt 以内)にある一番近い候補。無ければ nil。
    public static func snapPoint(_ time: Double, excluding id: String?, project: Project, playhead: Double, pps: Double, enabled: Bool) -> Double? {
        guard enabled, pps > 0 else { return nil }
        var best: Double?
        var bestDist = Double.infinity
        for p in snapCandidates(excluding: id, project: project, playhead: playhead) {
            let d = abs(p - time)
            if d * pps < snapThresholdPoints && d < bestDist { best = p; bestDist = d }
        }
        return best
    }

    /// 吸着した時刻(吸着しなければそのまま)。
    public static func snapTime(_ time: Double, excluding id: String?, project: Project, playhead: Double, pps: Double, enabled: Bool) -> Double {
        snapPoint(time, excluding: id, project: project, playhead: playhead, pps: pps, enabled: enabled) ?? time
    }

    // MARK: ドラッグ

    /// クリップの場所(レイヤー番号とその中の番号)。
    public static func locate(_ clipId: String, in project: Project) -> (track: Int, index: Int)? {
        for (ti, tr) in project.tracks.enumerated() {
            if let ci = tr.clips.firstIndex(where: { $0.id == clipId }) { return (ti, ci) }
        }
        return nil
    }

    /// 素材の時間軸を持つクリップか(トリムで offset が動く / 右端が素材の長さで止まる)。
    public static func hasSourceTimeline(_ type: ClipType) -> Bool {
        type == .video || type == .audio || type == .voice
    }

    /// 本体のドラッグ: 頭と終わりの両方を吸着させる(startDrag と同じ: 頭を吸着 → 終わりを吸着したら終わりに合わせて戻す)。
    /// `targetTrackIndex` が別のレイヤーなら、そこへ移す(元のレイヤーから外して、行き先の末尾に足す)。nil / 範囲外 / 同じなら動かさない。
    public static func move(in project: Project, clipId: String, deltaT: Double, targetTrackIndex: Int?, playhead: Double, pps: Double, snapEnabled: Bool) -> Result {
        guard let loc = locate(clipId, in: project) else { return Result(project: project, guides: []) }
        var p = project
        var clip = p.tracks[loc.track].clips[loc.index]
        let dur = clip.duration
        func snap(_ t: Double) -> Double? { snapPoint(t, excluding: clipId, project: project, playhead: playhead, pps: pps, enabled: snapEnabled) }

        var ns = max(0, clip.start + deltaT)
        let sp = snap(ns)
        if let sp { ns = sp }
        let ep = snap(ns + dur)
        if let ep, ep != ns + dur { ns = ep - dur }
        ns = max(0, ns)
        clip.start = ns
        let end = ns + dur
        let guides = [sp, ep].compactMap { $0 }.filter { abs($0 - ns) < 1e-9 || abs($0 - end) < 1e-9 }

        if let to = targetTrackIndex, to != loc.track, p.tracks.indices.contains(to) {
            p.tracks[loc.track].clips.remove(at: loc.index)
            p.tracks[to].clips.append(clip)
        } else {
            p.tracks[loc.track].clips[loc.index] = clip
        }
        return Result(project: p, guides: dedup(guides))
    }

    /// 右端のトリム: duration = max(0.05, 吸着した終わり − 頭)。素材の時間軸があるクリップは (srcDuration − offset) も超えない。
    public static func trimRight(in project: Project, clipId: String, deltaT: Double, playhead: Double, pps: Double, snapEnabled: Bool) -> Result {
        guard let loc = locate(clipId, in: project) else { return Result(project: project, guides: []) }
        var p = project
        var clip = p.tracks[loc.track].clips[loc.index]
        let raw = clip.start + max(minDuration, clip.duration + deltaT)
        let sp = snapPoint(raw, excluding: clipId, project: project, playhead: playhead, pps: pps, enabled: snapEnabled)
        let ne = sp ?? raw
        var d = max(minDuration, ne - clip.start)
        if hasSourceTimeline(clip.type), let src = clip.srcDuration {
            d = max(minDuration, min(d, src - clip.offset))
        }
        clip.duration = d
        p.tracks[loc.track].clips[loc.index] = clip
        let end = clip.start + d
        let guides = [sp].compactMap { $0 }.filter { abs($0 - end) < 1e-9 }
        return Result(project: p, guides: guides)
    }

    /// 左端のトリム: 新しい頭 = clamp(吸着(頭 + dt), 0, 終わり − 0.05)。d = 新しい頭 − 頭。duration −= d。
    /// 素材の時間軸があるクリップ(video / audio / voice)だけ offset += d とし、素材の頭より左へは広げない(d ≥ −offset)。
    /// 画像・文字・ぼかしは offset に触らない(Electron 版は全種類に足していたが、意味がないので変えた)。
    public static func trimLeft(in project: Project, clipId: String, deltaT: Double, playhead: Double, pps: Double, snapEnabled: Bool) -> Result {
        guard let loc = locate(clipId, in: project) else { return Result(project: project, guides: []) }
        var p = project
        var clip = p.tracks[loc.track].clips[loc.index]
        let start0 = clip.start, dur0 = clip.duration, end = start0 + dur0
        // もともと 0.05 秒より短いクリップは、それ以上縮めない(勝手に伸ばさない)
        let minD = min(minDuration, dur0)
        let maxStart = max(start0, end - minD)
        let raw = min(max(0, start0 + deltaT), maxStart)
        let sp = snapPoint(raw, excluding: clipId, project: project, playhead: playhead, pps: pps, enabled: snapEnabled)
        let ns = min(max(0, sp ?? raw), maxStart)
        var d = ns - start0
        let timed = hasSourceTimeline(clip.type)
        if timed { d = max(d, -clip.offset) }
        d = max(d, -start0)
        d = min(d, dur0 - minD)
        clip.start = start0 + d
        clip.duration = dur0 - d
        if timed { clip.offset = clip.offset + d }
        // キーフレームは絵に付いたまま(頭が d 進んだら、頭からの時刻は −d)
        if clip.hasKeyframes { clip.keyframes = Animation.shifted(clip.keyframes, by: -d) }
        p.tracks[loc.track].clips[loc.index] = clip
        let guides = [sp].compactMap { $0 }.filter { abs($0 - clip.start) < 1e-9 }
        return Result(project: p, guides: guides)
    }

    private static func dedup(_ v: [Double]) -> [Double] {
        var out: [Double] = []
        for x in v where !out.contains(where: { abs($0 - x) < 1e-9 }) { out.append(x) }
        return out
    }

    // MARK: 分割 / 削除

    /// `t` が頭と終わりの間(端は含まない)のときだけ (左, 右) を返す。右は新しい id・start = t・duration = 終わり − t。
    /// 素材の時間軸があるクリップだけ右の offset に切った長さを足す。
    public static func split(_ clip: Clip, at t: Double) -> (left: Clip, right: Clip)? {
        let end = clip.start + clip.duration
        guard t > clip.start, t < end else { return nil }
        let cut = t - clip.start
        var left = clip
        left.duration = cut
        var right = clip
        right.id = newId()
        right.start = t
        right.duration = end - t
        if hasSourceTimeline(clip.type) { right.offset = clip.offset + cut }
        // キーフレームは切れ目で振り分ける(両側に境目のキーを足して、値が途切れないようにする)
        if clip.hasKeyframes {
            let parts = Animation.split(clip.keyframes, at: cut)
            left.keyframes = parts.left
            right.keyframes = parts.right
        }
        return (left, right)
    }

    /// プロジェクトの中のクリップを分割する。右のクリップは左のすぐ後ろに入れる。分割できなければ nil。
    public static func split(in project: Project, clipId: String, at t: Double) -> (project: Project, rightId: String)? {
        guard let loc = locate(clipId, in: project),
              let (l, r) = split(project.tracks[loc.track].clips[loc.index], at: t) else { return nil }
        var p = project
        p.tracks[loc.track].clips[loc.index] = l
        p.tracks[loc.track].clips.insert(r, at: loc.index + 1)
        return (p, r.id)
    }

    /// クリップを消す。無ければ nil。
    public static func delete(in project: Project, clipId: String) -> Project? {
        guard let loc = locate(clipId, in: project) else { return nil }
        var p = project
        p.tracks[loc.track].clips.remove(at: loc.index)
        return p
    }

    // MARK: 素材の追加

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    public static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "ogg"]
    public static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v"]
    /// 「素材を追加」と ドラッグ&ドロップで受ける拡張子。
    public static var mediaExtensions: [String] { Array(imageExtensions.union(audioExtensions).union(videoExtensions)).sorted() }

    /// 拡張子から種類を決める(画像 / 音声 以外は動画)。
    public static func kindOf(path: String) -> ClipType {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        return .video
    }

    public static func isSupportedMedia(path: String) -> Bool {
        mediaExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// 素材の長さ(秒)。画像は 5 秒。音声・動画は AVURLAsset で測り、測れなければ 5 秒。
    public static func probeDuration(url: URL, kind: ClipType) async -> Double {
        if kind == .image { return defaultMediaDuration }
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return defaultMediaDuration }
        let s = d.seconds
        return (s.isFinite && s > 0) ? s : defaultMediaDuration
    }

    /// 置き先のレイヤー: [t, t+dur) に重なるクリップがなく、ボイスもないレイヤーのうち最初のもの。無ければ 0 番。
    public static func placementTrack(in project: Project, start t: Double, duration dur: Double) -> Int {
        let i = project.tracks.firstIndex { tr in
            tr.clips.allSatisfy { c in c.type != .voice && (c.start >= t + dur || c.start + c.duration <= t) }
        }
        return i ?? 0
    }

    /// Electron 版 addMedia が作るクリップ(x .5, y .5, scale 1, opacity 1, volume 1, offset 0。画像以外は srcDuration つき)。
    public static func makeMediaClip(path: String, kind: ClipType, duration: Double, start: Double) -> Clip {
        var c = Clip()
        c.type = kind
        c.src = path
        c.start = start
        c.duration = duration
        c.srcDuration = kind == .image ? nil : duration
        c.offset = 0
        c.x = 0.5; c.y = 0.5; c.scale = 1; c.opacity = 1; c.volume = 1
        return c
    }

    /// 素材を `start` に 1 つずつ置く(置くたびに空きレイヤーを探し直す)。置いたクリップの id を順に返す。
    public static func place(media: [(path: String, kind: ClipType, duration: Double)], at start: Double, in project: inout Project) -> [String] {
        var ids: [String] = []
        if project.tracks.isEmpty { project.tracks.append(Track(name: "レイヤー1")) }
        for m in media {
            let ti = placementTrack(in: project, start: start, duration: m.duration)
            let c = makeMediaClip(path: m.path, kind: m.kind, duration: m.duration, start: start)
            project.tracks[ti].clips.append(c)
            ids.append(c.id)
        }
        return ids
    }

    // MARK: テキスト / ぼかし範囲

    /// 解像度に合わせた大きさの係数(renderer.js resK)。
    public static func resK(_ project: Project) -> Double {
        (Double(project.width) * Double(project.height) / (1920.0 * 1080.0)).squareRoot()
    }

    /// テキストクリップ(3 秒、x .5、y .15、文字 96 × resK(最小 8)、白、縁 #000000、既定フォント)。
    public static func makeTextClip(at t: Double, project: Project) -> Clip {
        var c = Clip()
        c.type = .text
        c.text = "テキスト"
        c.start = t
        c.duration = 3
        c.x = 0.5; c.y = 0.15
        c.fontSize = max(8, (96 * resK(project)).rounded())
        c.color = "#ffffff"
        c.outline = "#000000"
        c.font = defaultFonts[0]
        c.opacity = 1
        return c
    }

    /// ぼかし範囲(3 秒、x .5、y .5、w .3、h .3、強さ 24 × resK、四角)。
    public static func makeBlurClip(at t: Double, project: Project) -> Clip {
        var c = Clip()
        c.type = .blur
        c.start = t
        c.duration = 3
        c.x = 0.5; c.y = 0.5; c.w = 0.3; c.h = 0.3
        c.strength = (24 * resK(project)).rounded()
        c.shape = "rect"
        return c
    }

    /// 一番上のレイヤー(配列の最後)の末尾にクリップを足す。レイヤーが 1 つもなければ作る。
    public static func appendToTopLayer(_ clip: Clip, in project: inout Project) {
        if project.tracks.isEmpty { project.tracks.append(Track(name: "レイヤー1")) }
        project.tracks[project.tracks.count - 1].clips.append(clip)
    }
}
