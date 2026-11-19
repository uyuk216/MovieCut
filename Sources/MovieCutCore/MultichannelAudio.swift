import Foundation

// MARK: - マルチチャンネル音声(5.1ch 等 → ステレオ)
//
// 現状と設計の全文は docs/マルチチャンネル音声.md。
// 要点:
// - このアプリのミックス・書き出し・再生はすべて 48 kHz ステレオ前提
//   (`AudioMixer.mixdown` が唯一の合流点で、プレビューも書き出しもここを通る)。
// - マルチチャンネル素材は、読み込み段(`AudioMixer` の PCMSource)で
//   ステレオへダウンミックスしてから渡す。黙って ch0/ch1 だけ拾って
//   センター(セリフ)やサラウンドを捨てる、という従来の挙動をやめる。
// - 係数は ITU-R BS.775 の Lo/Ro ダウンミックス:
//     Lo = L + 0.7071*C + 0.7071*Ls (+ 0.7071*Lb)
//     Ro = R + 0.7071*C + 0.7071*Rs (+ 0.7071*Rb)
//   LFE は BS.775 の Lo/Ro では含めない(低域専用チャンネルで、
//   ステレオスピーカーでは再生帯域外のことが多く、混ぜると濁るため)。
//   追加の正規化はしない(複数クリップの合算と同じく、最終段で
//   `AudioMixer` が -1〜1 にクリップする。従来のステレオ/モノラル素材は
//   係数が恒等/複製なのでビット同一になる)。
// - チャンネルの並びは「位置による前提」で決める(レイアウト情報を使わない)。
//   WAV 系(ffmpeg / WAVE_FORMAT_EXTENSIBLE の標準順)を前提とする:
//     1ch: モノラル / 2ch: L R / 3ch: L R C / 4ch: L R Ls Rs(クアッド)
//     5ch: L R C Ls Rs / 6ch: L R C LFE Ls Rs(5.1)
//     7ch: L R C LFE Ls Rs Cs / 8ch: L R C LFE Lb Rb Ls Rs(7.1 の WAV 順。
//     Lb/Rb と Ls/Rs は左右が同じなので、ダウンミックス係数は区別しない)
//   9ch 以上は 8ch 分を 7.1 として扱い、残りは左右交互に 0.7071 で足す
//   (捨てて無音にしないための保険。本来の役割は不明なので docs に明記)。
// - AAC 等でチャンネル順がレイアウト依存のコンテナ(mp4 の動画音声)は、
//   `AssetPCMSource` が従来どおり AVFoundation に 2ch 変換を任せる
//   (レイアウトを知っているのは AVFoundation 側)。チャンネル選択を
//   指定したときだけ素材のチャンネル数のまま読んで自前で処理する
//   (その場合の並び前提は WAV 順。docs 参照)。

/// 素材の各チャンネルの役割(位置による前提)。
public enum AudioChannelRole: String, CaseIterable, Equatable, Sendable {
    case left, right, center, lfe, leftSurround, rightSurround, leftBack, rightBack, centerSurround, unknown

    /// 日本語の短い名前(UI・診断用)。
    public var label: String {
        switch self {
        case .left: return "左"
        case .right: return "右"
        case .center: return "センター"
        case .lfe: return "LFE"
        case .leftSurround: return "左サラウンド"
        case .rightSurround: return "右サラウンド"
        case .leftBack: return "左バック"
        case .rightBack: return "右バック"
        case .centerSurround: return "後方センター"
        case .unknown: return "不明"
        }
    }
}

/// 素材チャンネルの使い方(クリップ単位。`Clip.channelMode` に保存する)。
/// 未設定(nil)= `.downmix` で、ファイルには書かない。
public enum SourceChannelMode: String, Codable, CaseIterable, Equatable, Sendable {
    /// 全チャンネルを BS.775 係数でステレオへダウンミックス(既定)。
    case downmix
    /// 最初の 2 チャンネルだけを使う(従来の挙動。ステレオペアが先頭にある素材用)。
    case firstPair
    /// センターだけを左右同じに出す(5.1 のセリフだけを聞きたいとき)。
    /// センターの役割のチャンネルが無い素材ではダウンミックスに倒す(無音にしない)。
    case center

    /// UI に出す名前。
    public var label: String {
        switch self {
        case .downmix: return "ステレオにダウンミックス"
        case .firstPair: return "最初の2チャンネル"
        case .center: return "センターのみ"
        }
    }
}

/// マルチチャンネル → ステレオの純粋な計算(ファイル IO を含まない)。
public enum MultichannelDownmix {
    /// センター/サラウンドの係数(1/√2 = -3.01 dB。ITU-R BS.775 の Lo/Ro)。
    public static let surroundGain: Float = 0.70710677

    /// チャンネル数から各チャンネルの役割を決める(位置による前提。上のコメント参照)。
    public static func roles(channelCount: Int) -> [AudioChannelRole] {
        switch max(0, channelCount) {
        case 0: return []
        case 1: return [.center]   // モノラル(左右同相で出す。係数は stereoWeights 側で扱う)
        case 2: return [.left, .right]
        case 3: return [.left, .right, .center]
        case 4: return [.left, .right, .leftSurround, .rightSurround]
        case 5: return [.left, .right, .center, .leftSurround, .rightSurround]
        case 6: return [.left, .right, .center, .lfe, .leftSurround, .rightSurround]
        case 7: return [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .centerSurround]
        case 8: return [.left, .right, .center, .lfe, .leftBack, .rightBack, .leftSurround, .rightSurround]
        default:
            var r = roles(channelCount: 8)
            for i in 8..<channelCount { r.append(i % 2 == 0 ? .leftSurround : .rightSurround) }
            return r
        }
    }

    /// 役割 1 つ分のステレオ係数。
    public static func weight(for role: AudioChannelRole) -> (l: Float, r: Float) {
        let g = surroundGain
        switch role {
        case .left: return (1, 0)
        case .right: return (0, 1)
        case .center, .centerSurround: return (g, g)
        case .lfe: return (0, 0)   // BS.775 Lo/Ro では LFE を含めない
        case .leftSurround, .leftBack: return (g, 0)
        case .rightSurround, .rightBack: return (0, g)
        case .unknown: return (g, g)
        }
    }

    /// チャンネルごとのステレオ係数(`mode` 適用済み)。長さは `channelCount`。
    public static func stereoWeights(channelCount: Int, mode: SourceChannelMode = .downmix) -> [(l: Float, r: Float)] {
        let n = max(0, channelCount)
        guard n > 0 else { return [] }
        if n == 1 { return [(1, 1)] }   // モノラルはどのモードでも左右同じ(従来どおり)
        switch mode {
        case .downmix:
            return roles(channelCount: n).map { weight(for: $0) }
        case .firstPair:
            return (0..<n).map { i in i == 0 ? (l: Float(1), r: Float(0)) : (i == 1 ? (l: Float(0), r: Float(1)) : (l: Float(0), r: Float(0))) }
        case .center:
            let rs = roles(channelCount: n)
            guard rs.contains(.center) else { return roles(channelCount: n).map { weight(for: $0) } }
            return rs.map { $0 == .center ? (l: Float(1), r: Float(1)) : (l: Float(0), r: Float(0)) }
        }
    }

    /// チャンネル別のサンプル列をステレオ 2 列にする(純粋関数)。
    /// 長さが違うチャンネルは最短に合わせる。1ch は左右複製、2ch+downmix は恒等に一致する。
    public static func downmix(channels: [[Float]], mode: SourceChannelMode = .downmix) -> (left: [Float], right: [Float]) {
        guard !channels.isEmpty else { return ([], []) }
        let n = channels.map(\.count).min() ?? 0
        guard n > 0 else { return ([], []) }
        if channels.count == 1 { return (channels[0], channels[0]) }
        let w = stereoWeights(channelCount: channels.count, mode: mode)
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        for (c, ch) in channels.enumerated() {
            let (wl, wr) = (w[c].l, w[c].r)
            if wl == 0 && wr == 0 { continue }
            for i in 0..<n {
                l[i] += ch[i] * wl
                r[i] += ch[i] * wr
            }
        }
        return (l, r)
    }

    /// 素材がマルチチャンネル(3ch 以上)か。
    public static func isMultichannel(channelCount: Int) -> Bool { channelCount > 2 }
}

// MARK: - クリップ側の読み出し

public extension Clip {
    /// 素材チャンネルの使い方。未設定・不正値は `.downmix`。
    var channelModeOrDefault: SourceChannelMode { channelMode ?? .downmix }
    /// チャンネルの使い方が既定(ダウンミックス)でないか。
    var hasChannelMode: Bool { channelMode != nil && channelMode != .downmix }
    /// チャンネル選択を受けられるクリップ(音声・ボイス・動画。パン等と同じ対象)。
    static func supportsChannelMode(_ c: Clip) -> Bool { supportsAudioFx(c) }
}
