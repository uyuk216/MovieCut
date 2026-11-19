import Foundation

// トラックミキサー(レイヤー単位の音量・パン)の純粋ロジック。
// - 保存は `Track.volume` / `Track.pan`(標準は書かない)。消音・ソロは既存の `Project.isAudible` が正。
// - ミックス段(`AudioMixer`)は、クリップ側の音量・パン・フェード等を掛けた後段で、ここの左右ゲインを掛ける。

/// 1 つのレイヤーのトラックゲイン設定。
public struct TrackMix: Equatable, Sendable {
    /// 線形の音量(0〜2)。
    public var gain: Double
    /// パン(-1〜1)。
    public var pan: Double

    public init(gain: Double = 1, pan: Double = 0) {
        self.gain = gain
        self.pan = pan
    }

    /// 何もしない設定(音量 1・中央)。
    public static let identity = TrackMix(gain: 1, pan: 0)
    public var isIdentity: Bool { gain == 1 && pan == 0 }

    /// レイヤーの設定から作る(未設定は identity、範囲外は丸める)。
    public static func of(_ track: Track) -> TrackMix {
        TrackMix(gain: track.trackVolumeOrDefault, pan: track.trackPanOrDefault)
    }

    /// 左右にかける倍率: 音量 × `AudioPan.gains`(等パワー。中央は左右とも音量どおり)。
    public var stereoGains: (l: Float, r: Float) {
        let g = AudioPan.gains(pan)
        let k = Float(gain)
        return (k * g.l, k * g.r)
    }

    /// 下限の dB(無音は -inf でなくこの値として扱う)。
    public static let minDb: Double = -60

    /// 線形の音量 → dB(`20 log10`)。0 以下・有限でない値は `minDb`。
    public static func db(forGain gain: Double) -> Double {
        guard gain.isFinite, gain > 0 else { return minDb }
        return max(20 * log10(gain), minDb)
    }

    /// dB → 線形の音量。`minDb` 以下は 0(無音)。
    public static func gain(forDb db: Double) -> Double {
        guard db.isFinite, db > minDb else { return 0 }
        return pow(10, db / 20)
    }

    /// この設定の音量を dB で(`db(forGain:)`)。
    public var db: Double { Self.db(forGain: gain) }
}

/// 平らにしたクリップに添える、左右別のトラックゲイン。入れ子(複合クリップ・シーン)は乗算で合成する。
public struct TrackMixGains: Equatable, Sendable {
    public var l: Float
    public var r: Float

    public init(l: Float = 1, r: Float = 1) {
        self.l = l
        self.r = r
    }

    public static let identity = TrackMixGains(l: 1, r: 1)
    public var isIdentity: Bool { l == 1 && r == 1 }

    /// 内側のレイヤーの設定を掛けたゲイン(要素ごとの乗算)。
    public func multiplied(by mix: TrackMix) -> TrackMixGains {
        let g = mix.stereoGains
        return TrackMixGains(l: l * g.l, r: r * g.r)
    }
}

public enum TrackMixer {
    /// レイヤーごとに音が出るか(`Project.isAudible`)。`project.tracks` と同じ順。
    public static func audibleTracks(in project: Project) -> [Bool] {
        project.tracks.map { project.isAudible($0) }
    }
}
