import Foundation

// MARK: - クリップの属性

public extension Clip {
    /// 速度・逆再生が使える種類(動画・音声)。ボイスは声の長さが決まっているので対象外。
    static func supportsSpeed(_ type: ClipType) -> Bool { type == .video || type == .audio }

    /// フリーズフレームのクリップか(動画だけ)。
    var isFreeze: Bool { type == .video && (freeze ?? false) }
    /// 保存されている速度(範囲 0.25〜4 に収める。壊れた値・未設定は 1)。
    var speedOrDefault: Double { ClipTiming.clampSpeed(speed ?? 1) }
    var reverseOrDefault: Bool { reverse ?? false }
    var keepPitchOrDefault: Bool { keepPitch ?? true }
    /// 速度ランプの点(整えた後。ランプが無い・対応しない種類・フリーズは nil)。
    var rampPoints: [SpeedKey]? {
        guard Clip.supportsSpeed(type), !isFreeze, let r = speedRamp else { return nil }
        return SpeedRamp.sanitized(r, duration: duration)
    }
    /// 描画・音声が実際に使う速度(対応しない種類・フリーズは 1)。速度ランプは、長さ全体の平均の速さ。
    var effectiveSpeed: Double {
        if let r = rampPoints { return duration > 0 ? SpeedRamp.integral(r, upTo: duration) / duration : 1 }
        return Clip.supportsSpeed(type) && !isFreeze ? speedOrDefault : 1
    }
    /// 描画・音声が実際に使う逆再生(速度ランプと同時には使わない)。
    var effectiveReverse: Bool { Clip.supportsSpeed(type) && !isFreeze && reverseOrDefault && rampPoints == nil }
    /// 時間の流れが「そのまま」でない(速度が 1 でない・逆再生・フリーズ・速度ランプ)。
    var hasTimeRemap: Bool { effectiveSpeed != 1 || effectiveReverse || isFreeze || rampPoints != nil }
    /// 音声の処理(伸び縮み・逆順・速度ランプ)が必要か。フリーズは無音なので含めない。
    var hasAudioRemap: Bool { !isFreeze && (effectiveSpeed != 1 || effectiveReverse || rampPoints != nil) }
    /// コマの補間(フレームブレンドかオプティカルフロー)が設定されているか(動画・順再生・フリーズでない)。実際に効くのは速度が 1 未満のときだけ(`ClipTiming.blendsFrames`)。
    var frameBlendOn: Bool { (frameBlend == true || frameFlow == true) && type == .video && !isFreeze && !effectiveReverse }
    /// 補間にオプティカルフローを使うか(`frameBlendOn` のうち、`frameFlow` が true のもの)。
    var opticalFlowOn: Bool { frameFlow == true && frameBlendOn }
}

// MARK: - 時間の対応(タイムライン ⇄ 素材)

/// クリップの時間と素材の時間の対応(純粋な計算)。
///
/// - `duration` はタイムライン上の長さ(これが正)。使う素材の長さ `sourceSpan` = duration × speed。
///   使う素材の範囲は [offset, offset + sourceSpan]。
/// - 順再生: 素材の時刻 = offset + t × speed(t = クリップの頭からの時刻)。
/// - 逆再生: 素材の時刻 = offset + sourceSpan − t × speed(頭が範囲の終わり、終わりが範囲の頭 = offset)。
/// - フリーズ: 素材の時刻は常に offset。
public enum ClipTiming {
    public static let minSpeed = 0.25
    public static let maxSpeed = 4.0
    /// インスペクタ・メニューの目安の速度。
    public static let presets: [Double] = [0.25, 0.5, 1, 2, 4]
    /// フリーズフレームの長さ(秒)の既定。
    public static let freezeLength = 2.0

    /// 0.25〜4 に収める(NaN・0 以下は 1)。
    public static func clampSpeed(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 1 }
        return min(max(v, minSpeed), maxSpeed)
    }

    /// 使う素材の長さ(秒)。フリーズは 0。
    public static func sourceSpan(_ c: Clip) -> Double {
        if c.isFreeze { return 0 }
        if let r = c.rampPoints { return SpeedRamp.integral(r, upTo: c.duration) }
        return c.duration * c.effectiveSpeed
    }

    /// クリップの頭からの時刻 `t`(秒)に出す、素材の時刻。範囲の外もそのまま延長して計算する(切り詰めは呼び出し側)。
    public static func sourceTime(of c: Clip, atClipTime t: Double) -> Double {
        if c.isFreeze { return c.offset }
        if let r = c.rampPoints { return c.offset + SpeedRamp.integral(r, upTo: t) }
        let s = c.effectiveSpeed
        if c.effectiveReverse { return c.offset + c.duration * s - t * s }
        return c.offset + t * s
    }

    /// `sourceTime` の逆: 素材の時刻 `source` が出るクリップの頭からの時刻。フリーズは決まらないので nil。
    public static func clipTime(of c: Clip, forSourceTime source: Double) -> Double? {
        if c.isFreeze { return nil }
        if let r = c.rampPoints { return SpeedRamp.time(r, forIntegral: source - c.offset) }
        let s = c.effectiveSpeed
        if c.effectiveReverse { return (c.offset + c.duration * s - source) / s }
        return (source - c.offset) / s
    }

    /// 描画が素材から取るコマの時刻。順再生・フリーズは `sourceTime` そのまま(速度 1・順再生は従来の `時刻 − start + offset` と同じ値)。
    /// 逆再生は、書き出しの1コマ(長さ 1/fps)が覆う素材の区間の「手前の端」を取る
    /// (= 順再生で区間の頭を取るのの鏡。0 秒から 30 コマの素材を 30fps で逆再生すると 29, 28, …, 0 の順になる)。
    public static func frameSourceTime(of c: Clip, atClipTime t: Double, fps: Double) -> Double {
        let s = sourceTime(of: c, atClipTime: t)
        if c.effectiveReverse, fps > 0 { return max(0, s - c.effectiveSpeed / fps) }
        return s
    }

    /// 時刻 `t`(頭から)の速度。速度ランプは、その時刻の値(直線補間)。
    public static func speed(of c: Clip, atClipTime t: Double) -> Double {
        if let r = c.rampPoints { return SpeedRamp.speed(r, at: t) }
        return c.effectiveSpeed
    }

    /// 隣り合う 2 コマを混ぜるか(フレームブレンドが on で、その時刻の速度が 1 未満)。
    public static func blendsFrames(_ c: Clip, atClipTime t: Double) -> Bool {
        c.frameBlendOn && speed(of: c, atClipTime: t) < 1
    }

    /// タイムラインの小さな印("×2" "◀" "◀×0.5" "静止")。通常のクリップは nil。
    public static func badge(for c: Clip) -> String? {
        if c.isFreeze { return "静止" }
        if c.rampPoints != nil { return "ランプ" }
        guard Clip.supportsSpeed(c.type) else { return nil }
        let s = c.effectiveSpeed
        var out = ""
        if c.effectiveReverse { out += "◀" }
        if s != 1 { out += "×" + formatSpeed(s) }
        return out.isEmpty ? nil : out
    }

    /// 0.5 → "0.5"、2 → "2"、1.25 → "1.25"(小数 2 桁まで、末尾の 0 は消す)。
    public static func formatSpeed(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// 「元の長さ → 新しい長さ」の表示(使う素材の長さ → タイムライン上の長さ)。
    public static func lengthReadout(for c: Clip) -> String {
        String(format: "%.2f 秒 → %.2f 秒", sourceSpan(c), c.duration)
    }
}

// MARK: - 編集

/// 速度・逆再生・フリーズフレームの編集(純粋な計算。UI にも Undo にも依存しない)。変えたときだけ true を返す。
public enum SpeedEditing {
    public static func supports(_ c: Clip) -> Bool { Clip.supportsSpeed(c.type) && !c.isFreeze }

    /// 長さをマイクロ秒に丸める(割り算の誤差がファイルに出ないように)。
    static func rounded(_ d: Double) -> Double { (d * 1_000_000).rounded() / 1_000_000 }

    /// 速度を変える。頭の位置と素材の頭(offset)はそのままで、長さを 使う素材の長さ ÷ 新しい速度 にする
    /// (つまり、同じ範囲の素材を新しい速度で見せる)。後ろのクリップは動かさない(ずらさない)。
    /// 速度 1 は「未設定」に戻す。同じ値なら何もしない。
    @discardableResult
    public static func setSpeed(_ c: inout Clip, _ v: Double) -> Bool {
        guard supports(c) else { return false }
        let new = ClipTiming.clampSpeed(v)
        if c.rampPoints == nil, new == c.effectiveSpeed, (new != 1 || c.speed == nil), c.extra["speed"] == nil { return false }
        let span = ClipTiming.sourceSpan(c)
        c.extra["speed"] = nil
        c.speedRamp = nil
        c.speed = new == 1 ? nil : new
        c.duration = max(ClipEditing.minDuration, rounded(span / new))
        return true
    }

    /// 速度を変える。同じレイヤーの次のクリップに重ならないよう、延びる分は次のクリップの頭までで止める
    /// (止めるとき、使う素材は頭に近い側を残す = 順再生は終わりを、逆再生は素材の頭側を切る)。次のクリップがすでに重なっているときは、いまの終わりまで。
    /// 変えたときだけ新しい Project を返す。
    public static func settingSpeed(in project: Project, clipId: String, _ v: Double) -> Project? {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return nil }
        var p = project
        var c = p.tracks[loc.track].clips[loc.index]
        let oldDuration = c.duration
        let oldEnd = c.start + oldDuration
        let span = ClipTiming.sourceSpan(c)
        guard setSpeed(&c, v) else { return nil }
        if c.duration > oldDuration + 1e-9 {
            let next = p.tracks[loc.track].clips.enumerated()
                .filter { $0.offset != loc.index && $0.element.start > c.start + ClipEditing.timeEpsilon }
                .map(\.element.start).min()
            if let next {
                let limit = max(oldEnd, next) - c.start
                if c.duration > limit + 1e-9 {
                    c.duration = max(ClipEditing.minDuration, rounded(limit))
                    if c.effectiveReverse {
                        // 頭(タイムラインの左端)に出る素材のコマは変えない: 範囲の終わり = 古い offset + span を保つ
                        let newSpan = c.duration * c.effectiveSpeed
                        c.offset = max(0, c.offset + span - newSpan)
                    }
                }
            }
        }
        p.tracks[loc.track].clips[loc.index] = c
        return p
    }

    /// 逆再生の切り替え。使う素材の範囲と長さはそのまま、向きだけ変える。
    @discardableResult
    public static func setReverse(_ c: inout Clip, _ on: Bool) -> Bool {
        guard supports(c), c.reverseOrDefault != on || c.extra["reverse"] != nil else { return false }
        if on, c.rampPoints != nil { return false }   // 速度ランプと逆再生は一緒に使わない
        c.extra["reverse"] = nil
        c.reverse = on ? true : nil
        return true
    }

    /// 音程を保つ(既定)/ 保たない。
    @discardableResult
    public static func setKeepPitch(_ c: inout Clip, _ on: Bool) -> Bool {
        guard supports(c), c.keepPitchOrDefault != on || c.extra["keepPitch"] != nil else { return false }
        c.extra["keepPitch"] = nil
        c.keepPitch = on ? nil : false
        return true
    }

    // MARK: フリーズフレーム

    /// 再生位置 `t` でフリーズフレームにできるか(動画で、フリーズ以外。頭を含み、終わりは含まない)。
    public static func canFreeze(_ c: Clip, at t: Double) -> Bool {
        c.type == .video && !c.isFreeze && c.duration > 0 && t >= c.start - ClipEditing.timeEpsilon && t < c.start + c.duration - ClipEditing.timeEpsilon
    }

    /// 再生位置 `t` の1コマを止めた静止画のクリップ(`length` 秒)を作る。見た目の設定(位置・拡大・エフェクト…)は元のクリップのまま、
    /// 動かしていた項目はその時刻の値で固定する。音・速度・逆再生・トランジション・フェードは付けない。
    public static func makeFreezeClip(from c: Clip, at t: Double, fps: Double, length: Double = ClipTiming.freezeLength) -> Clip {
        let rel = min(max(0, t - c.start), c.duration)
        var f = c
        f.id = newId()
        f.start = t
        f.duration = length
        f.freeze = true
        f.offset = max(0, ClipTiming.frameSourceTime(of: c, atClipTime: rel, fps: fps))
        f.speed = nil; f.reverse = nil; f.keepPitch = nil
        f.transitionIn = nil; f.transitionOut = nil
        f.fadeIn = nil; f.fadeOut = nil; f.fadeCurve = nil
        f.extra["speed"] = nil; f.extra["reverse"] = nil; f.extra["keepPitch"] = nil
        // 動かしていた項目は、その時刻の値で固定する
        for key in c.keyframes.keys { f.setStaticValue(Animation.value(of: key, in: c, at: rel), of: key) }
        f.keyframes = [:]
        return f
    }

    /// クリップを再生位置で割って、間に静止画を挟む(同じレイヤーの、このクリップの後ろにあるクリップは静止画の長さだけ後ろへずらす)。
    /// 再生位置が頭ちょうどなら割らずに、静止画を頭に入れてクリップごとずらす。できなければ nil。
    public static func freezeFrame(in project: Project, clipId: String, at t: Double, length: Double = ClipTiming.freezeLength) -> (project: Project, freezeId: String)? {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return nil }
        let clip = project.tracks[loc.track].clips[loc.index]
        guard canFreeze(clip, at: t), length > 0 else { return nil }
        let freeze = makeFreezeClip(from: clip, at: t, fps: project.fps, length: length)
        var p = project
        let end = clip.start + clip.duration
        var pieces: [Clip] = []
        if t <= clip.start + ClipEditing.timeEpsilon {
            var first = freeze
            first.start = clip.start
            first.transitionIn = clip.transitionIn     // 頭のトランジションは静止画が引き継ぐ
            var right = clip
            right.start = clip.start + length
            right.transitionIn = nil; right.fadeIn = nil
            pieces = [first, right]
        } else if let (l, r) = ClipEditing.split(clip, at: t) {
            var right = r
            right.start = t + length
            pieces = [l, freeze, right]
        } else {
            return nil
        }
        // 後ろのクリップをずらす(元のクリップの終わり以降に始まるもの)
        for i in p.tracks[loc.track].clips.indices where i != loc.index {
            if p.tracks[loc.track].clips[i].start >= end - ClipEditing.timeEpsilon { p.tracks[loc.track].clips[i].start += length }
        }
        p.tracks[loc.track].clips.remove(at: loc.index)
        p.tracks[loc.track].clips.insert(contentsOf: pieces, at: loc.index)
        return (p, freeze.id)
    }
}

// MARK: - 速度ランプの編集

extension SpeedEditing {
    /// 速度ランプを決める(nil で外す)。作るとき、逆再生は外れ、速度は点の列が決める。外すと、いまの平均の速さの一定速度になる
    /// (長さも使う素材の長さも変わらない)。点は `SpeedRamp.sanitized` で整えてから入れる。変えたときだけ true を返す。
    @discardableResult
    public static func setRamp(_ c: inout Clip, _ pts: [SpeedKey]?) -> Bool {
        guard supports(c) else { return false }
        let current = c.rampPoints
        let new: [SpeedKey]? = pts.flatMap { SpeedRamp.sanitized($0, duration: c.duration) }
        if pts != nil && new == nil { return false }
        if new == current { return false }
        if let n = new {
            c.speedRamp = n
            c.speed = nil
            c.reverse = nil
        } else {
            let avg = c.effectiveSpeed
            c.speedRamp = nil
            c.speed = avg == 1 ? nil : ClipTiming.clampSpeed(avg)
        }
        return true
    }
}
