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

    /// 吸着の候補: 0、再生ヘッド、`excluding` 以外の全クリップの頭と終わり、マーカー、範囲の印(in / out)。
    static func snapCandidates(excluding id: String?, project: Project, playhead: Double) -> [Double] {
        var pts = [0, playhead]
        for c in project.allClips where c.id != id { pts.append(c.start); pts.append(c.start + c.duration) }
        for m in project.markers { pts.append(m.time) }
        if let r = project.rangeIn { pts.append(r) }
        if let r = project.rangeOut { pts.append(r) }
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

    /// トリム・分割で offset を動かす(素材の時間が流れる)クリップか。フリーズ(1コマで止まる)は動かさない。
    /// 複合クリップも、中身の時刻(offset)で頭・分割の位置を持つ(描画・音声が offset を読む)。
    static func movesSource(_ clip: Clip) -> Bool { (hasSourceTimeline(clip.type) || clip.type == .compound) && !clip.isFreeze }

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

    /// 右端のトリム: duration = max(0.05, 吸着した終わり − 頭)。素材の時間軸があるクリップは (srcDuration − offset) ÷ 速度 も超えない。
    /// 逆再生は右端が素材の頭側なので、縮めると offset が進み、延ばすと offset が戻る(0 まで)。
    public static func trimRight(in project: Project, clipId: String, deltaT: Double, playhead: Double, pps: Double, snapEnabled: Bool) -> Result {
        guard let loc = locate(clipId, in: project) else { return Result(project: project, guides: []) }
        var p = project
        var clip = p.tracks[loc.track].clips[loc.index]
        let raw = clip.start + max(minDuration, clip.duration + deltaT)
        let sp = snapPoint(raw, excluding: clipId, project: project, playhead: playhead, pps: pps, enabled: snapEnabled)
        let ne = sp ?? raw
        var d = max(minDuration, ne - clip.start)
        if movesSource(clip) {
            let rate = clip.effectiveSpeed
            if let ramp = clip.rampPoints {
                // 速度ランプ: 右端の素材の時刻は積分で決まる。素材の終わりを越えない
                if let src = clip.srcDuration {
                    d = max(minDuration, min(d, SpeedRamp.time(ramp, forIntegral: src - clip.offset)))
                }
                clip.speedRamp = SpeedRamp.fit(ramp, to: d)
            } else if clip.effectiveReverse {
                // 逆再生は右端が素材の頭側(offset)。素材の頭より前へは延ばせない。縮めた分は offset が進む(見えているコマは動かない)
                let dur0 = clip.duration
                d = max(minDuration, min(d, dur0 + clip.offset / rate))
                clip.offset = max(0, clip.offset - (d - dur0) * rate)
            } else if let src = clip.srcDuration {
                d = max(minDuration, min(d, (src - clip.offset) / rate))
            }
        }
        clip.duration = d
        p.tracks[loc.track].clips[loc.index] = clip
        let end = clip.start + d
        let guides = [sp].compactMap { $0 }.filter { abs($0 - end) < 1e-9 }
        return Result(project: p, guides: guides)
    }

    /// 左端のトリム: 新しい頭 = clamp(吸着(頭 + dt), 0, 終わり − 0.05)。d = 新しい頭 − 頭。duration −= d。
    /// 素材の時間軸があるクリップ(video / audio / voice)だけ offset += d × 速度 とし、素材の頭より左へは広げない(d ≥ −offset ÷ 速度)。逆再生は offset を動かさない。
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
        let moves = movesSource(clip)
        let ramp = clip.rampPoints
        // 速度ランプの頭の側は、頭の最初の速度で決まる(頭を前へ延ばすときも同じ速さで足す)
        let rate = ramp?.first?.v ?? clip.effectiveSpeed
        let rev = clip.effectiveReverse
        if moves && !rev { d = max(d, -clip.offset / rate) }
        else if moves && rev, let src = clip.srcDuration {
            // 逆再生は左端が素材の終わり側。素材の終わりを越えて延ばせない
            d = max(d, -max(0, src - clip.offset - dur0 * rate) / rate)
        }
        d = max(d, -start0)
        d = min(d, dur0 - minD)
        clip.start = start0 + d
        clip.duration = dur0 - d
        // 順再生は頭の側(offset)が進む。逆再生の頭は素材の終わりなので、offset は動かない
        if moves && !rev {
            if let ramp {
                // 頭を d 進めた分の素材の長さは積分(前へ延ばすときは最初の速度のまま)。ランプの点も同じだけ詰める/足す
                clip.offset += d > 0 ? SpeedRamp.integral(ramp, upTo: d) : d * rate
                clip.speedRamp = d > 0 ? SpeedRamp.split(ramp, at: d).right : SpeedRamp.extendedHead(ramp, by: -d)
            } else {
                clip.offset = clip.offset + d * rate
            }
        }
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
        if movesSource(clip) {
            let sp = clip.effectiveSpeed
            if let ramp = clip.rampPoints {
                // 速度ランプ: 左は [0, cut]、右は [cut, 終わり] の点。右の素材の頭は積分で決まる
                let parts = SpeedRamp.split(ramp, at: cut)
                left.speedRamp = parts.left
                right.speedRamp = parts.right
                right.offset = clip.offset + SpeedRamp.integral(ramp, upTo: cut)
            } else if clip.effectiveReverse {
                // 逆再生は、左の断片が素材の終わり側。右の断片の offset は元のまま
                left.offset = clip.offset + (clip.duration - cut) * sp
            } else {
                right.offset = clip.offset + cut * sp
            }
        }
        // トランジション・音声フェード: 頭の効果は左、終わりの効果は右(切れ目に新しい効果は付けない)
        left.transitionOut = nil; left.fadeOut = nil
        right.transitionIn = nil; right.fadeIn = nil
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
            !tr.isLocked && tr.clips.allSatisfy { c in c.type != .voice && (c.start >= t + dur || c.start + c.duration <= t) }
        }
        return i ?? (project.tracks.firstIndex { !$0.isLocked } ?? 0)
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

    /// レイヤー `track` が [t, t+dur) で空いているか(存在し、ロックでもボイス入りでもなく、重なるクリップがない)。
    static func isFree(_ project: Project, track: Int, start t: Double, duration dur: Double) -> Bool {
        guard project.tracks.indices.contains(track) else { return false }
        let tr = project.tracks[track]
        return !tr.isLocked && tr.clips.allSatisfy { c in c.type != .voice && (c.start >= t + dur || c.start + c.duration <= t) }
    }

    /// [t, t+dur) が空いている、ロックでもボイス入りでもない最初のレイヤー。無ければ nil(重ねない)。
    public static func freeTrack(in project: Project, start t: Double, duration dur: Double) -> Int? {
        project.tracks.firstIndex { tr in
            !tr.isLocked && tr.clips.allSatisfy { c in c.type != .voice && (c.start >= t + dur || c.start + c.duration <= t) }
        }
    }

    /// 素材を `start` から順に置く: 最初は `start`、2 つ目以降は直前のクリップの終わりに。
    /// 置き先は、その区間が空いている最初のレイヤー(ロック・ボイス入りは除く)。空きが無ければ新しいレイヤーを足す。
    /// 同じレイヤーのクリップは重ならない(2026-11-02 修正: 以前は全部 `start` に置いて、満杯だと 0 番に重ねていた)。
    /// 置いたクリップの id を順に返す。
    /// `preferredTrack` があり、その区間が空いていれば(ロック・ボイス入りでなければ)そのレイヤーを先に使う(ドロップ先のレイヤー)。
    public static func place(media: [(path: String, kind: ClipType, duration: Double)], at start: Double, preferredTrack: Int? = nil, in project: inout Project) -> [String] {
        var ids: [String] = []
        if project.tracks.isEmpty { project.tracks.append(Track(name: "レイヤー1")) }
        var cursor = start
        for m in media {
            let ti: Int
            if let pref = preferredTrack, isFree(project, track: pref, start: cursor, duration: m.duration) {
                ti = pref
            } else if let f = freeTrack(in: project, start: cursor, duration: m.duration) {
                ti = f
            } else {
                project.tracks.append(Track(name: "レイヤー\(project.tracks.count + 1)"))
                ti = project.tracks.count - 1
            }
            let c = makeMediaClip(path: m.path, kind: m.kind, duration: m.duration, start: cursor)
            project.tracks[ti].clips.append(c)
            ids.append(c.id)
            cursor += m.duration
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

    /// 調整レイヤー(3 秒・エフェクトなし。エフェクトは後から足す。素材を持たない)。
    public static func makeAdjustmentClip(at t: Double, project: Project) -> Clip {
        var c = Clip()
        c.type = .adjustment
        c.start = t
        c.duration = 3
        return c
    }

    /// 音声ビジュアライザ(3 秒・画面の下に横長の枠・白の棒 32 本。見た目は既定のまま `visualizer` を置かない)。
    public static func makeVisualizerClip(at t: Double, project: Project) -> Clip {
        var c = Clip()
        c.type = .visualizer
        c.start = t
        c.duration = 3
        c.x = 0.5; c.y = 0.85; c.w = 0.6; c.h = 0.2
        return c
    }

    /// 図形(3 秒・画面の中央・種類ごとの既定の大きさ)。見た目は既定のまま、種類だけ `figure` に書く(四角形は書かない)。
    public static func makeShapeClip(_ kind: FigureKind, at t: Double, project: Project) -> Clip {
        var c = Clip()
        c.type = .shape
        c.start = t
        c.duration = 3
        c.x = 0.5; c.y = 0.5
        c.w = kind.defaultSize.w; c.h = kind.defaultSize.h
        c.figure = Figure(kind: kind.rawValue).normalized
        return c
    }

    /// 一番上のレイヤー(配列の最後)の末尾にクリップを足す。レイヤーが 1 つもなければ作る。
    public static func appendToTopLayer(_ clip: Clip, in project: inout Project) {
        if project.tracks.isEmpty { project.tracks.append(Track(name: "レイヤー1")) }
        // 一番上がロックされていれば、ロックされていない新しいレイヤーを足して、そこへ置く
        if project.tracks[project.tracks.count - 1].isLocked { project.tracks.append(Track(name: "レイヤー\(project.tracks.count + 1)")) }
        project.tracks[project.tracks.count - 1].clips.append(clip)
    }
}
