import Foundation
import AVFoundation

/// J/K/L のシャトル再生の速度状態(純粋なロジック)。
/// 速さは段階で決まる: -4 / -2 / -1 / 停止 / 1 / 2 / 4 倍。J は一段遅く(逆再生側へ)、L は一段速く、K で停止。
/// 停止からの J は逆 1 倍、停止からの L は順 1 倍。
public struct ShuttleState: Equatable {
    /// 速さの段(左ほど逆再生が速い)。
    public static let ladder: [Double] = [-4, -2, -1, 0, 1, 2, 4]
    /// 停止の段のインデックス。
    public static let stopIndex = 3
    /// 順 1 倍の段のインデックス(通常の再生)。
    public static let normalIndex = 4

    public static let stopped = ShuttleState(index: stopIndex)
    public static let normal = ShuttleState(index: normalIndex)

    public private(set) var index: Int

    private init(index: Int) { self.index = index }

    /// 再生の速さ(倍率。負は逆再生、0 は停止)。
    public var speed: Double { Self.ladder[index] }
    public var isStopped: Bool { index == Self.stopIndex }

    /// step が正なら L 側(速く)、負なら J 側(遅く・逆へ)に一段動かす。段の外には出ない。
    public func moved(by step: Int) -> ShuttleState {
        ShuttleState(index: min(max(index + step, 0), Self.ladder.count - 1))
    }

    /// K: 停止。
    public var stoppedState: ShuttleState { .stopped }
}

// MARK: - シャトルの音(2 倍・4 倍)


/// L / J のシャトルで 2 倍・4 倍のとき、音も同じ速さで鳴らす。クリップの速度変更(`AudioRemap`)と同じ部品
/// (AVAudioUnitTimePitch / AVAudioUnitVarispeed)を使い、「音程を保つ」は既存のクリップの設定(`keepPitch`)に合わせる。
public enum ShuttleAudio {
    /// 音を出す速さの範囲(順方向のみ。逆再生と 1 倍以下の段は、1 倍は通常再生・逆再生は無音)。
    public static let speedRange: ClosedRange<Double> = 1.0001...4

    /// この速さのシャトルで音を出すか。
    public static func playsAudio(speed: Double) -> Bool { speedRange.contains(speed) }

    /// 時刻 t に鳴っている音声クリップのどれかが「音程を保たない」(`keepPitch == false`)なら false、それ以外は true(既定は保つ)。
    public static func keepsPitch(in project: Project, at t: Double) -> Bool {
        for c in CompoundEditing.audibleClips(in: project)
        where [ClipType.audio, .voice, .video].contains(c.type) && t >= c.start && t < c.start + c.duration {
            if c.keepPitch == false { return false }
        }
        return true
    }

    /// 速さを変える部品。音程を保つなら TimePitch(rate = speed, pitch = 0)、保たないなら Varispeed。
    /// `AudioRemap`(書き出し・ミックス)と、再生中のシャトルで同じものを使う。
    public static func makeRateUnit(rate: Double, keepPitch: Bool) -> AVAudioUnit {
        if keepPitch {
            let u = AVAudioUnitTimePitch()
            u.rate = Float(rate); u.pitch = 0
            return u
        }
        let u = AVAudioUnitVarispeed()
        u.rate = Float(rate)
        return u
    }
}
