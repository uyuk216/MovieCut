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
//   `AssetPCMSource` が既定では従来どおり AVFoundation に 2ch 変換を任せる
//   (レイアウトを知っているのは AVFoundation 側)。チャンネル選択を指定したときだけ
//   素材のチャンネル数のまま読んで自前で処理する。この経路は素材のレイアウト順
//   (例: AAC 5.1 は C L R Ls Rs LFE)で返ってくるので、位置前提(WAV 順)ではなく
//   トラックの AudioChannelLayout から役割を決める(`roles(forLayoutTag:)` /
//   `role(forChannelLabel:)`、改善ラウンド5 Phase A)。レイアウトが取れない・未知のタグ
//   のときだけ従来の位置前提(`roles(channelCount:)`)にフォールバックする。

/// 素材の各チャンネルの役割(レイアウト情報、無ければ位置による前提で決める)。
public enum AudioChannelRole: String, CaseIterable, Equatable, Sendable {
    case left, right, center, lfe, leftSurround, rightSurround, leftBack, rightBack, centerSurround, unknown
    /// 前方の左右センター(MPEG 7.1 A/B の Lc/Rc)。L/R と中央の間のスピーカー。
    case leftCenter, rightCenter

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
        case .leftCenter: return "左センター寄り"
        case .rightCenter: return "右センター寄り"
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
        case .leftSurround, .leftBack, .leftCenter: return (g, 0)
        case .rightSurround, .rightBack, .rightCenter: return (0, g)
        case .unknown: return (g, g)
        }
    }

    /// チャンネルごとのステレオ係数(`mode` 適用済み)。長さは `channelCount`。
    /// 位置前提の役割(`roles(channelCount:)`)で `stereoWeights(roles:mode:)` を呼ぶ薄いラッパ
    /// (File 経路 = WAV 系用。従来と挙動は同じ)。
    public static func stereoWeights(channelCount: Int, mode: SourceChannelMode = .downmix) -> [(l: Float, r: Float)] {
        stereoWeights(roles: roles(channelCount: max(0, channelCount)), mode: mode)
    }

    /// 役割ごとのステレオ係数(`mode` 適用済み)。長さは `roles.count`。
    /// モードの意味は「位置」ではなく「役割」で定義する(素材のレイアウト順に依らない):
    /// - `.downmix`: 役割ごとの BS.775 係数(`weight(for:)`)
    /// - `.firstPair`: 役割が L のチャンネルだけ左(1,0)、R だけ右(0,1)、他は 0。
    ///   「素材先頭の 2ch」ではなく「L/R ペアを取り出す」が意味(AAC 5.1 は先頭が C なので位置では取れない)
    /// - `.center`: 役割が C のチャンネルだけ(1,1)、他は 0。C が無ければ `.downmix` に倒す(無音にしない)
    /// - 1ch(モノラル)はどのモードでも左右同じ(1,1)(従来どおり)
    public static func stereoWeights(roles: [AudioChannelRole], mode: SourceChannelMode = .downmix) -> [(l: Float, r: Float)] {
        let n = roles.count
        guard n > 0 else { return [] }
        if n == 1 { return [(1, 1)] }   // モノラルはどのモードでも左右同じ(従来どおり)
        switch mode {
        case .downmix:
            return roles.map { weight(for: $0) }
        case .firstPair:
            return roles.map { role in
                switch role {
                case .left: return (l: Float(1), r: Float(0))
                case .right: return (l: Float(0), r: Float(1))
                default: return (l: Float(0), r: Float(0))
                }
            }
        case .center:
            guard roles.contains(.center) else { return roles.map { weight(for: $0) } }
            return roles.map { $0 == .center ? (l: Float(1), r: Float(1)) : (l: Float(0), r: Float(0)) }
        }
    }

    // MARK: レイアウト情報(AudioChannelLayout)からの役割
    //
    // AVFoundation 型に依存させず UInt32(CoreAudio の AudioChannelLayoutTag / AudioChannelLabel の生値)で
    // 受けるので、Linux でも単体テストできる。数値は CoreAudioBaseTypes.h の定義
    // (タグは `(レイアウトID << 16) | チャンネル数`)。取り違えを防ぐため、Mac 側のテスト
    // (AssetChannelModeLayoutTests)で実際の kAudioChannelLayoutTag_* / kAudioChannelLabel_* と突き合わせている。
    // レイアウトが取れない・ここに無いタグ(未知)のとき nil / `.unknown` を返し、
    // 呼び出し側は従来の位置前提(`roles(channelCount:)`)にフォールバックする。

    /// レイアウトタグから、チャンネル順(= 素材が返すサンプルの並び)の役割表を返す。
    /// 未知のタグ・`UseChannelDescriptions`(0)・`UseChannelBitmap`・チャンネル数が合わないタグは nil。
    public static func roles(forLayoutTag tag: UInt32) -> [AudioChannelRole]? {
        let id = tag >> 16, count = Int(tag & 0xFFFF)
        let r: [AudioChannelRole]
        switch id {
        case 100: r = [.center]                                   // Mono
        case 101, 102, 103: r = [.left, .right]                   // Stereo / StereoHeadphones / MatrixStereo(Lt Rt)
        case 108: r = [.left, .right, .leftSurround, .rightSurround]   // Quadraphonic(= AAC_Quadraphonic)
        case 113: r = [.left, .right, .center]                    // MPEG_3_0_A
        case 114: r = [.center, .left, .right]                    // MPEG_3_0_B(= AAC_3_0)
        case 115: r = [.left, .right, .center, .centerSurround]   // MPEG_4_0_A
        case 116: r = [.center, .left, .right, .centerSurround]   // MPEG_4_0_B(= AAC_4_0)
        case 117: r = [.left, .right, .center, .leftSurround, .rightSurround]   // MPEG_5_0_A
        case 118: r = [.left, .right, .leftSurround, .rightSurround, .center]   // MPEG_5_0_B
        case 119: r = [.left, .center, .right, .leftSurround, .rightSurround]   // MPEG_5_0_C
        case 120: r = [.center, .left, .right, .leftSurround, .rightSurround]   // MPEG_5_0_D(= AAC_5_0)
        case 121: r = [.left, .right, .center, .lfe, .leftSurround, .rightSurround]   // MPEG_5_1_A
        case 122: r = [.left, .right, .leftSurround, .rightSurround, .center, .lfe]   // MPEG_5_1_B
        case 123: r = [.left, .center, .right, .leftSurround, .rightSurround, .lfe]   // MPEG_5_1_C
        case 124: r = [.center, .left, .right, .leftSurround, .rightSurround, .lfe]   // MPEG_5_1_D(= AAC_5_1)
        case 125: r = [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .centerSurround]   // MPEG_6_1_A
        case 126: r = [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .leftCenter, .rightCenter]   // MPEG_7_1_A
        case 127: r = [.center, .leftCenter, .rightCenter, .left, .right, .leftSurround, .rightSurround, .lfe]   // MPEG_7_1_B(= AAC_7_1)
        case 128: r = [.left, .right, .center, .lfe, .leftSurround, .rightSurround, .leftBack, .rightBack]   // MPEG_7_1_C
        case 141: r = [.center, .left, .right, .leftSurround, .rightSurround, .centerSurround]   // AAC_6_0((141<<16)|6)
        case 142: r = [.center, .left, .right, .leftSurround, .rightSurround, .centerSurround, .lfe]   // AAC_6_1((142<<16)|7)
        case 143: r = [.center, .left, .right, .leftSurround, .rightSurround, .leftBack, .rightBack]   // AAC_7_0((143<<16)|7)
        // 144 は AAC_Octagonal(8ch)で役割表を持たないため nil(位置前提へフォールバック)
        default: return nil
        }
        return r.count == count ? r : nil
    }

    /// `AudioChannelLabel`(UseChannelDescriptions のときのチャンネルごとのラベル)から役割へ。
    /// 扱わないラベル・未使用/不明は `.unknown`(呼び出し側で位置前提へフォールバックさせる)。
    public static func role(forChannelLabel label: UInt32) -> AudioChannelRole {
        switch label {
        case 1, 38: return .left              // Left / LeftTotal(Lt)
        case 2, 39: return .right             // Right / RightTotal(Rt)
        case 3, 42: return .center            // Center / Mono
        case 4, 37: return .lfe               // LFEScreen / LFE2
        case 5, 10: return .leftSurround      // LeftSurround / LeftSurroundDirect
        case 6, 11: return .rightSurround     // RightSurround / RightSurroundDirect
        case 7: return .leftCenter            // LeftCenter
        case 8: return .rightCenter           // RightCenter
        case 9, 44: return .centerSurround    // CenterSurround / CenterSurroundDirect
        case 33: return .leftBack             // RearSurroundLeft(LeftBackSurround)
        case 34: return .rightBack            // RearSurroundRight(RightBackSurround)
        default: return .unknown
        }
    }

    /// チャンネルごとのラベル列から役割表を作る。`.unknown` が 1 つでも混じる・空なら nil(位置前提へ)。
    public static func roles(forChannelLabels labels: [UInt32]) -> [AudioChannelRole]? {
        guard !labels.isEmpty else { return nil }
        let r = labels.map { role(forChannelLabel: $0) }
        return r.contains(.unknown) ? nil : r
    }

    // MARK: 5.1 書き出し用の配置(改善ラウンド5 Phase B)

    /// 5.1 中間形式の canonical 順(L R C LFE Ls Rs)のチャンネル番号。
    public static let surround51ChannelCount = 6
    public static let ch51L = 0, ch51R = 1, ch51C = 2, ch51LFE = 3, ch51Ls = 4, ch51Rs = 5

    /// 素材チャンネル 1 つ(役割 `role`)を 5.1 canonical 順(0=L,1=R,2=C,3=LFE,4=Ls,5=Rs)のどこへ何倍で置くか。
    /// 役割どおりのパススルーが基本で、5.1 に無い役割は近い位置へ折り畳む:
    /// - Lb / Rb(7.1 の後方)→ Ls / Rs へ 0.7071
    /// - Cs(後方センター)→ Ls と Rs へ各 0.7071
    /// - Lc / Rc(MPEG 7.1 A/B の前方左右センター)→ L / R へ 0.7071(ステレオ係数 `weight(for:)` と同じ向き)
    /// - unknown(8ch 超の余り): `extraIndex` が偶数なら Ls、奇数なら Rs へ 0.7071(従来ダウンミックスの保険と同じ交互)。
    ///   `extraIndex` が nil なら両サラウンドへ 0.7071(`weight(for: .unknown)` と同じ)
    public static func surround51Placement(for role: AudioChannelRole, extraIndex: Int? = nil) -> [(channel: Int, gain: Float)] {
        let g = surroundGain
        switch role {
        case .left: return [(ch51L, 1.0)]
        case .right: return [(ch51R, 1.0)]
        case .center: return [(ch51C, 1.0)]
        case .lfe: return [(ch51LFE, 1.0)]
        case .leftSurround: return [(ch51Ls, 1.0)]
        case .rightSurround: return [(ch51Rs, 1.0)]
        case .leftBack: return [(ch51Ls, g)]
        case .rightBack: return [(ch51Rs, g)]
        case .centerSurround: return [(ch51Ls, g), (ch51Rs, g)]
        case .leftCenter: return [(ch51L, g)]
        case .rightCenter: return [(ch51R, g)]
        case .unknown:
            guard let i = extraIndex else { return [(ch51Ls, g), (ch51Rs, g)] }
            return [(i % 2 == 0 ? ch51Ls : ch51Rs, g)]
        }
    }

    /// 素材の全チャンネルぶんの配置表(長さは `roles.count`)。クリップの `mode` を反映する:
    /// - 1ch(モノラル): `.firstPair` だけ左右(各 1.0。従来のステレオ化と同じ)、他は C(1.0)
    /// - `.downmix`(2ch 以上): 役割どおりのパススルー(`surround51Placement`)。ステレオ素材は L/R のまま
    /// - `.firstPair`: 役割ベースのステレオ係数(L/R の役割だけ)で L/R へ
    /// - `.center`: センターの役割があればそのチャンネルだけ C へ(1.0)。無ければステレオ係数(ダウンミックス)で L/R へ
    public static func surround51Placements(roles: [AudioChannelRole], mode: SourceChannelMode = .downmix) -> [[(channel: Int, gain: Float)]] {
        let n = roles.count
        guard n > 0 else { return [] }
        func fromStereo(_ w: [(l: Float, r: Float)]) -> [[(channel: Int, gain: Float)]] {
            w.map { x in
                var p: [(channel: Int, gain: Float)] = []
                if x.l != 0 { p.append((ch51L, x.l)) }
                if x.r != 0 { p.append((ch51R, x.r)) }
                return p
            }
        }
        if n == 1 { return mode == .firstPair ? fromStereo([(1, 1)]) : [[(ch51C, Float(1))]] }
        switch mode {
        case .downmix:
            return roles.enumerated().map { (i, r) -> [(channel: Int, gain: Float)] in surround51Placement(for: r, extraIndex: r == .unknown ? i : nil) }
        case .firstPair:
            return fromStereo(stereoWeights(roles: roles, mode: .firstPair))
        case .center:
            guard roles.contains(.center) else { return fromStereo(stereoWeights(roles: roles, mode: .downmix)) }
            return roles.map { (r: AudioChannelRole) -> [(channel: Int, gain: Float)] in r == .center ? [(ch51C, Float(1))] : [] }
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
