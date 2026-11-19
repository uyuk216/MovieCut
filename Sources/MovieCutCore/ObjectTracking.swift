import Foundation
import CoreGraphics

// MARK: - オブジェクトトラッキング(W3-03 / YMM4 監査 #53)
//
// 既存の `MotionTrack`(中央の矩形を追い、重ねクリップの x・y キーを作る簡易版)を土台に、
// 「任意の開始矩形 → 位置と大きさの追跡 → 追跡結果そのものの保存 → 追従の適用先の拡張」
// を担う層。追跡結果は `ObjectTrack` として追従クリップ(`Clip.tracking`)に保存され、
// 適用はキーフレームへの焼き込み(従来方式と互換)で行う。
// - 変形クリップ(画像・動画・文字・図形・立ち絵・複合): x・y・scale(大きさ)で追従
// - ぼかし範囲クリップ: x・y・w・h で矩形そのものに追従(任意対象のぼかし追従。
//   顔ぼかしエフェクトの track は顔検出専用なので、任意対象はこちらを使う)
// 追跡の実行(`collect`)は進捗コールバックとキャンセル判定を受け取る同期ループで、
// 非同期実行・進捗表示・キャンセルは呼び出し側(アプリ層)が Task で包む。
// Vision の実走は `MotionTrack` の `VisionRectTracker` をそのまま使う。
//
// 失敗時の扱い(R4-5): Vision が見失っても静止矩形を返し続けることがあるため(R4-4 の実測)、
// 観測の信頼度を `TrackingLossGate` で判定し、低信頼の観測は採用しない。失敗が続いて
// 見失いが確定したら、その先頭の時刻で追跡を打ち切り、結果(`ObjectTrack.lostAt`)に残す。
// 見失い以降のサンプル・キーフレームは作らない。

/// 正規化座標(0〜1・左上原点)の矩形。ファイルには x・y・w・h で書く。
public struct TrackRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public init(_ r: CGRect) { self.init(x: Double(r.minX), y: Double(r.minY), w: Double(r.width), h: Double(r.height)) }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    public var centerX: Double { x + w / 2 }
    public var centerY: Double { y + h / 2 }
    public var area: Double { w * h }

    public var isValid: Bool { x.isFinite && y.isFinite && w.isFinite && h.isFinite && w > 0 && h > 0 }

    /// 範囲に収めたもの(位置は画面の少し外まで、大きさは正)。
    public var normalized: TrackRect {
        func c(_ v: Double, _ r: ClosedRange<Double>, _ d: Double) -> Double { v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d }
        return TrackRect(x: c(x, -1...2, 0), y: c(y, -1...2, 0), w: c(w, 0.001...2, 0.3), h: c(h, 0.001...2, 0.3))
    }
}

/// 追跡の 1 サンプル。`t` は追従クリップの頭からの秒。見失った時刻は `rect == nil`。
public struct TrackSample: Codable, Equatable, Sendable {
    public var t: Double
    public var rect: TrackRect?

    public init(t: Double, rect: TrackRect?) { self.t = t; self.rect = rect }
}

/// 追跡結果(クリップに保存される)。開始矩形を基準に、位置・大きさの変化を表す。
public struct ObjectTrack: Codable, Equatable, Sendable {
    /// 追跡元のクリップ(`Clip.id`)。
    public var sourceClipId: String
    /// 追跡を始めた矩形(基準)。
    public var startRect: TrackRect
    /// サンプル列(時刻順)。
    public var samples: [TrackSample] = []
    /// 見失いで打ち切った時刻(追従クリップの頭からの秒)。最後まで追えたら nil。
    /// 見失い以降のサンプル・キーフレームは作らない。ファイルに書くのは値があるときだけ
    /// (任意項目なので、古いファイルに無くても読み込みは従来どおり)。
    public var lostAt: Double? = nil

    public init(sourceClipId: String, startRect: TrackRect, samples: [TrackSample] = [], lostAt: Double? = nil) {
        self.sourceClipId = sourceClipId; self.startRect = startRect; self.samples = samples; self.lostAt = lostAt
    }

    public var hasValidSamples: Bool { samples.contains { $0.rect?.isValid == true } }

    /// 見失いで打ち切られた結果か。
    public var isLost: Bool { lostAt != nil }

    /// 最初の有効な矩形(基準。無ければ開始矩形)。
    public var referenceRect: TrackRect {
        samples.first { $0.rect?.isValid == true }?.rect ?? startRect
    }

    /// 時刻・値の整え(読み込み時)。見失い時刻がある結果は、その時刻以降のサンプルを持たない形に揃える。
    public var normalized: ObjectTrack {
        var o = self
        o.startRect = startRect.normalized
        o.samples = samples.filter { $0.t.isFinite && $0.t >= 0 }
            .map { TrackSample(t: $0.t, rect: $0.rect?.normalized) }
            .sorted { $0.t < $1.t }
        if let l = o.lostAt {
            if l.isFinite && l >= 0 {
                o.samples = o.samples.filter { $0.t < l }
            } else {
                o.lostAt = nil
            }
        }
        return o
    }

    /// 検出の無い区間をまたいで補間してよい最大の間隔(秒)。`FaceTrack.maxGap` と同じ考え方。
    public static let maxGap = 1.0

    /// 時刻 t の矩形。前後を線形補間する。前後どちらかまで maxGap を超える、または有効な検出が無いときは nil。
    public func rect(at t: Double) -> CGRect? {
        guard t.isFinite else { return nil }
        let valid = samples.filter { $0.rect?.isValid == true }
        guard !valid.isEmpty else { return nil }
        let before = valid.last { $0.t <= t }
        let after = valid.first { $0.t >= t }
        switch (before, after) {
        case let (b?, a?) where b.t == a.t:
            return b.rect!.cgRect
        case let (b?, a?):
            if a.t - b.t <= 2 * Self.maxGap, let p = b.rect, let q = a.rect {
                let k = (t - b.t) / (a.t - b.t)
                return TrackRect(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k,
                                 w: p.w + (q.w - p.w) * k, h: p.h + (q.h - p.h) * k).cgRect
            }
            if t - b.t <= Self.maxGap { return b.rect!.cgRect }
            if a.t - t <= Self.maxGap { return a.rect!.cgRect }
            return nil
        case let (b?, nil):
            return t - b.t <= Self.maxGap ? b.rect!.cgRect : nil
        case let (nil, a?):
            return a.t - t <= Self.maxGap ? a.rect!.cgRect : nil
        default:
            return nil
        }
    }
}

public enum ObjectTracking {
    /// サンプルの間隔(秒あたり回数)。`MotionTrack` と同じ 10。
    public static let sampleRate = MotionTrack.sampleRate
    /// 平滑化の時定数(秒)。`MotionTrack` と同じ。
    public static let smoothTau = MotionTrack.smoothTau

    /// 追従できるクリップ(位置を持つ映像系すべて。従来の MotionTrack は文字・図形・画像だけだった)。
    public static func canFollow(_ c: Clip) -> Bool {
        switch c.type {
        case .image, .video, .text, .shape, .tachie, .compound, .blur: return true
        default: return false
        }
    }

    /// 追跡元になる映像・画像: 対象クリップより下のレイヤーで、開始時刻にかかっている一番手前のもの。
    /// (対象が映像クリップ自身の場合は、それより下の映像が元になる。自分自身は元にならない。)
    public static func sourceClip(for id: String, in project: Project) -> Clip? {
        guard let loc = ClipEditing.locate(id, in: project) else { return nil }
        let follower = project.tracks[loc.track].clips[loc.index]
        guard canFollow(follower) else { return nil }
        for tr in project.tracks[0..<loc.track].reversed() where !tr.isHidden {
            if let v = tr.clips.last(where: { ($0.type == .video || $0.type == .image) && $0.src != nil && $0.id != id && follower.start >= $0.start && follower.start < $0.start + $0.duration }) {
                return v
            }
        }
        return nil
    }

    // MARK: 追跡の実行(進捗・キャンセル対応)

    /// 時刻 k / sampleRate のコマを順に追跡する。開始矩形は呼び出し側が決める(従来は中央固定だった)。
    /// - progress: 0〜1 を処理した割合で呼ぶ(毎サンプル)。
    /// - shouldCancel: true を返したら打ち切り、nil を返す(キャンセル)。
    /// - Returns: サンプルごとの矩形(見失いは nil)。キャンセル時は nil。
    public static func collect(duration: Double, startRect: CGRect, tracker: RectTracking,
                               frame: (Double) -> CGImage?,
                               progress: ((Double) -> Void)? = nil,
                               shouldCancel: (() -> Bool)? = nil) -> [CGRect?]? {
        collectRun(duration: duration, startRect: startRect, tracker: tracker, frame: frame,
                   progress: progress, shouldCancel: shouldCancel)?.rects
    }

    /// `collect` の見失い情報つき版。信頼できない観測(低信頼・無効な矩形・コマの欠落)は採用せず、
    /// `TrackingLossGate` で見失いが確定したら連続失敗の先頭で打ち切って、結果はそこまでの
    /// サンプルだけになる(見失い以降の観測は結果に残らない)。見失った時刻は `lostAt` に入る。
    /// キャンセル時は nil(部分結果は返さない)。
    public static func collectRun(duration: Double, startRect: CGRect, tracker: RectTracking,
                                  frame: (Double) -> CGImage?,
                                  progress: ((Double) -> Void)? = nil,
                                  shouldCancel: (() -> Bool)? = nil) -> TrackingRun? {
        let n = max(1, Int((max(duration, 0) * sampleRate).rounded(.up)) + 1)
        var out: [CGRect?] = []
        out.reserveCapacity(n)
        var started = false
        var gate = TrackingLossGate()
        for k in 0..<n {
            if shouldCancel?() == true { return nil }
            let t = Double(k) / sampleRate
            guard let img = frame(t) else {
                if started { _ = gate.evaluate(index: k, rect: nil, confidence: 0) }
                out.append(nil); progress?(Double(k + 1) / Double(n))
                if gate.isLost { break }
                continue
            }
            if !started {
                tracker.start(rect: startRect, image: img)
                started = true
                out.append(startRect)
            } else {
                let o = tracker.nextObservation(image: img)
                out.append(gate.evaluate(index: k, rect: o.rect, confidence: o.confidence) ? o.rect : nil)
            }
            progress?(Double(k + 1) / Double(n))
            if gate.isLost { break }
        }
        var lostAt: Double? = nil
        if let li = gate.lostIndex {
            lostAt = Double(li) / sampleRate
            out = Array(out.prefix(li))
        }
        return TrackingRun(rects: out, lostAt: lostAt)
    }

    /// 追跡の生結果 → 保存用のサンプル列。
    public static func samples(from rects: [CGRect?]) -> [TrackSample] {
        rects.enumerated().map { k, r in
            TrackSample(t: Double(k) / sampleRate, rect: r.map { TrackRect($0) })
        }
    }

    /// 追跡結果を作る。有効なサンプルが 1 つも無ければ nil。
    /// `lostAt` を渡すと見失い時刻を結果に保持し、その時刻以降のサンプルは持たない。
    public static func makeTrack(sourceClipId: String, startRect: CGRect, rects: [CGRect?], lostAt: Double? = nil) -> ObjectTrack? {
        var s = samples(from: rects)
        if let l = lostAt { s = s.filter { $0.t < l } }
        let track = ObjectTrack(sourceClipId: sourceClipId, startRect: TrackRect(startRect), samples: s, lostAt: lostAt)
        return track.hasValidSamples ? track : nil
    }

    // MARK: 追跡結果 → キーフレーム

    /// 追従に使うキーの集合(ぼかし範囲は矩形そのもの、それ以外は位置＋拡大)。
    public static func followKeys(for clip: Clip) -> [String] {
        clip.type == .blur ? ["x", "y", "w", "h"] : ["x", "y", "scale"]
    }

    /// 追跡結果から、追従クリップのキーフレームを作る。
    /// 見失った区間は直前の位置・大きさを保つ。変形クリップは「開始時点の対象との位置関係」と
    /// 「開始時点の大きさに対する比率」を保つ(位置は中心の差、拡大は面積比の平方根)。
    /// ぼかし範囲は矩形そのもの(中心と大きさ)に合わせる。平滑化は `AutoReframe.smooth`。
    public static func keyframes(track: ObjectTrack, follower: Clip) -> [String: [Keyframe]]? {
        // 見失い以降はキーにしない。見失い時刻が記録されていればその手前まで、
        // 無くても末尾の連続した見失いが確定量(`TrackingLossGate.consecutiveFailureLimit`)以上
        // 続く列は、その先頭の手前までで切る(直前の位置を保った静止キーを最後まで焼かない)。
        // 途中の短い見失いは従来どおり直前の位置・大きさを保持してつなぐ。
        var usable = track.samples
        if let l = track.lostAt {
            usable = usable.filter { $0.t < l }
        } else {
            let rects: [CGRect?] = usable.map { smp in smp.rect.flatMap { $0.isValid ? $0.cgRect : nil } }
            usable = Array(usable.prefix(TrackingLossGate.effectiveCount(samples: rects)))
        }
        let valid = usable.filter { $0.rect?.isValid == true }
        guard !valid.isEmpty else { return nil }
        let dt = usable.count > 1
            ? max(1 / sampleRate, (usable.last!.t - usable.first!.t) / Double(usable.count - 1))
            : 1 / sampleRate
        let ref = track.referenceRect
        // 見失いは直前の有効値を保持する列(中心 x・y、幅・高さ)
        var cx: [Double] = [], cy: [Double] = [], ws: [Double] = [], hs: [Double] = []
        var last = ref
        for s in usable {
            if let r = s.rect, r.isValid { last = r }
            cx.append(last.centerX); cy.append(last.centerY); ws.append(last.w); hs.append(last.h)
        }
        let times = usable.map { $0.t }
        func keys(_ values: [Double]) -> [Keyframe] {
            zip(times, values).map { Keyframe(t: $0.0, v: $0.1) }
        }
        if follower.type == .blur {
            let xs = AutoReframe.smooth(cx, dt: dt, tau: smoothTau)
            let ys = AutoReframe.smooth(cy, dt: dt, tau: smoothTau)
            let wv = AutoReframe.smooth(ws, dt: dt, tau: smoothTau)
            let hv = AutoReframe.smooth(hs, dt: dt, tau: smoothTau)
            return [
                "x": keys(xs.map { min(max($0, 0), 1) }),
                "y": keys(ys.map { min(max($0, 0), 1) }),
                "w": keys(wv.map { min(max($0, 0), 1) }),
                "h": keys(hv.map { min(max($0, 0), 1) }),
            ]
        }
        let baseX = Animation.value(of: "x", in: follower, at: 0)
        let baseY = Animation.value(of: "y", in: follower, at: 0)
        let baseScale = Animation.value(of: "scale", in: follower, at: 0)
        let xs = AutoReframe.smooth(cx.map { baseX + ($0 - ref.centerX) }, dt: dt, tau: smoothTau)
        let ys = AutoReframe.smooth(cy.map { baseY + ($0 - ref.centerY) }, dt: dt, tau: smoothTau)
        var out: [String: [Keyframe]] = [
            "x": keys(xs.map { Animation.clamp("x", $0, type: follower.type) }),
            "y": keys(ys.map { Animation.clamp("y", $0, type: follower.type) }),
        ]
        // 大きさ: 面積比の平方根。ほとんど変わらないときは scale キーを作らない(位置だけの追従を汚さない)
        let refArea = max(ref.area, 1e-9)
        let ratios = zip(ws, hs).map { ($0.0 * $0.1 / refArea).squareRoot() }
        if let maxDev = ratios.map({ abs($0 - 1) }).max(), maxDev > 0.02 {
            let ss = AutoReframe.smooth(ratios.map { baseScale * $0 }, dt: dt, tau: smoothTau)
            out["scale"] = keys(ss.map { Animation.clamp("scale", $0, type: follower.type) })
        }
        return out
    }

    /// 追跡結果をクリップへ適用する: 結果を `clip.tracking` に保存し、追従キーを書き換える。
    /// 既存の追従キー(x・y・scale、ぼかしは x・y・w・h)は置き換え、それ以外のキーは触らない。
    /// 変わらなければ false。
    @discardableResult
    public static func apply(track: ObjectTrack, to clip: inout Clip) -> Bool {
        guard canFollow(clip), let ks = keyframes(track: track, follower: clip) else { return false }
        let before = clip
        clip.tracking = track
        for key in followKeys(for: clip) { clip.keyframes[key] = nil }
        for (k, v) in ks { clip.keyframes[k] = v }
        return clip != before
    }

    /// 追従を取り消す: 保存した追跡結果と、追従で書いたキーを消す(キーの最終値を静的な値にして見た目を保つ)。
    @discardableResult
    public static func clearFollow(from clip: inout Clip, at t: Double = 0) -> Bool {
        guard clip.tracking != nil else { return false }
        for key in followKeys(for: clip) {
            if let ks = clip.keyframes[key], !ks.isEmpty {
                let v = Animation.interpolate(ks, at: t) ?? clip.staticValue(of: key)
                clip.keyframes[key] = nil
                clip.setStaticValue(Animation.clamp(key, v, in: clip), of: key)
            }
        }
        clip.tracking = nil
        return true
    }

    /// 追跡結果から「ぼかし範囲」クリップを作る(任意対象へのぼかし追従)。
    /// 顔ぼかしの一括付与(W2-08)は顔検出ベースだが、こちらは任意の対象を追うぼかし範囲を作る接続。
    public static func makeBlurFollower(track: ObjectTrack, start: Double, duration: Double) -> Clip {
        var c = Clip()
        c.type = .blur
        c.start = start
        c.duration = duration
        let ref = track.referenceRect
        c.x = min(max(ref.centerX, 0), 1)
        c.y = min(max(ref.centerY, 0), 1)
        c.w = min(max(ref.w, 0), 1)
        c.h = min(max(ref.h, 0), 1)
        _ = apply(track: track, to: &c)
        return c
    }
}
