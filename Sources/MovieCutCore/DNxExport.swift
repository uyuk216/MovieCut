import Foundation

// MARK: - DNxHR プロファイル(ffmpeg バックエンドの追加形式)
//
// ## 根拠(推測で決めていない。2026-11-19 に確認)
// - 対象 Mac の ffmpeg 9.0.2 で `ffmpeg -h encoder=dnxhd` を実測:
//   エンコーダ名は `dnxhd`(VC3/DNxHD)、対応ピクセル形式は
//   `yuv422p / yuv422p10le / yuv444p10le / gbrp10le`、
//   `-profile` の値は `dnxhd(0) / dnxhr_lb(1) / dnxhr_sq(2) / dnxhr_hq(3) / dnxhr_hqx(4) / dnxhr_444(5)`。
//   音声の PCM エンコーダ `pcm_s16le / pcm_s24le` も `-encoders` で存在を確認済み。
// - Academy Software Foundation の Encoding Guidelines「DNxHD Encoding」
//   (https://github.com/AcademySoftwareFoundation/EncodingGuidelines 、EncodeDNXHD.md):
//   プロファイル表(LB=8bit 4:2:2 圧縮比 22:1 / SQ=8bit 4:2:2 7:1 / HQ=8bit 4:2:2 4.5:1 /
//   HQX=10bit 4:2:2(規格上 12bit、ffmpeg は 10bit まで) / 444=10bit 4:4:4)、
//   「DNxHR は 256×120 以上の任意のフレームサイズを受け付け、ビットレートはサイズに比例して自動決定
//   (`-b:v` は効かない)」、「DNxHD(従来型)は 1920×1080 / 1440×1080 / 1280×720 / 960×720 の
//   4 サイズ×固定ビットレートの組み合わせのみ」と明記されている。
// - そのため本実装は DNxHR のみを対象にする。従来型 DNxHD は組み合わせが固定で、
//   プロジェクトの解像度・fps と一致しない限り書けず、DNxHR が HD サイズも包含するため見送った
//   (詳細は docs/DNxHR書き出し.md)。
//
// ## 対応範囲
// - 解像度: 幅 256 以上・高さ 120 以上(ffmpeg の下限)。上限は MovieCut の書き出し上限に合わせ
//   8192×4320 相当の面積まで(`OutputPlan.hevcSupports` と同じ物差し)。
//   奇数サイズは中間書き出し(既存 `Exporter`)が偶数へ切り下げるため、検証も偶数化後のサイズで行う。
//   偶数サイズを推奨する(ASWF ガイド: 奇数でも ffmpeg は通るが他アプリの受け入れは未確認)。
// - フレームレート: DNxHR は固定表が無く可変。MovieCut の入力範囲 1〜240fps をそのまま受ける
//   (23.976 / 29.97 / 59.94 等の NTSC レート含む)。インターレースは対象外(プログレッシブのみ)。
// - コンテナ: MOV(ProRes と同じ編集用コンテナ。音声は無圧縮 PCM)。
//   MXF(OP1a / OP-Atom)は今回対象外。

/// DNxHR の品質プロファイル。値(rawValue)は ffmpeg の `-profile:v` の接尾辞。
public enum DNxHRProfile: String, CaseIterable, Sendable {
    case lb
    case sq
    case hq
    case hqx
    /// 4:4:4 の仕上げ用。case 名は数字で始められないため finishing とし、rawValue が "444"。
    case finishing444 = "444"

    /// ffmpeg の `-profile:v` に渡す文字列("dnxhr_hq" 等)。
    public var ffmpegProfile: String { "dnxhr_\(rawValue)" }

    /// 表示名(書き出し形式の選択肢に出る)。
    public var title: String {
        switch self {
        case .lb: return "DNxHR LB"
        case .sq: return "DNxHR SQ"
        case .hq: return "DNxHR HQ"
        case .hqx: return "DNxHR HQX"
        case .finishing444: return "DNxHR 444"
        }
    }

    /// 日本語の短い説明(用途の目安)。
    public var summary: String {
        switch self {
        case .lb: return "低帯域(オフライン編集・プロキシ向け)"
        case .sq: return "標準品質"
        case .hq: return "高画質(通常の編集・納品向け)"
        case .hqx: return "高画質・10ビット(グレーディング向け)"
        case .finishing444: return "仕上げ用・4:4:4(VFX向け)"
        }
    }

    /// ffmpeg の `-pix_fmt`。エンコーダの対応形式(実測)の中からプロファイルに合うものを選ぶ。
    public var pixelFormat: String {
        switch self {
        case .lb, .sq, .hq: return "yuv422p"
        case .hqx: return "yuv422p10le"
        case .finishing444: return "yuv444p10le"
        }
    }

    /// ビット深度(ffmpeg で書ける値。規格上 HQX / 444 は 12 ビットまでだが ffmpeg は 10 ビットまで)。
    public var bitDepth: Int {
        switch self {
        case .lb, .sq, .hq: return 8
        case .hqx, .finishing444: return 10
        }
    }

    /// 色差サンプリング。
    public var chromaSubsampling: String { self == .finishing444 ? "4:4:4" : "4:2:2" }

    /// 音声エンコーダ(無圧縮 PCM。映像のビット深度に合わせて 16 / 24 ビット)。
    public var audioEncoder: String { bitDepth > 8 ? "pcm_s24le" : "pcm_s16le" }

    // MARK: 対応範囲の検証(純粋関数・テスト対象)

    /// ffmpeg の DNxHR エンコーダが受ける最小サイズ(ASWF ガイドで実測された下限)。
    public static let minWidth = 256
    public static let minHeight = 120

    /// このサイズ・fps で DNxHR 書き出しができるか。できないときは理由(日本語)、できるときは nil。
    /// サイズは中間書き出しが偶数へ切り下げた後の値で判定する(呼び出し側の生値を受け、ここで偶数化する)。
    public static func validationError(width: Int, height: Int, fps: Double) -> String? {
        let w = width & ~1, h = height & ~1
        if w < minWidth || h < minHeight {
            return "DNxHR は \(minWidth)×\(minHeight) 以上のサイズが必要です(書き出しサイズ \(w)×\(h))"
        }
        if !OutputPlan.hevcSupports(width: w, height: h) {
            return "このサイズは大きすぎて書き出せません(\(w)×\(h)。書き出せるのは 8192×4320 相当の面積までです"
        }
        guard fps.isFinite, fps >= FrameRate.minValue - 1e-9, fps <= FrameRate.maxValue + 1e-9 else {
            return "フレームレートが対応範囲外です(1〜240fps)"
        }
        return nil
    }
}

/// DNxHR 書き出しの計画(中間ファイルの決まり)。純粋関数の置き場。
public enum DNxExport {
    /// 中間ファイルに使う ProRes コーデック。
    /// DNxHR は中間コーデックとして H.264(8ビット)を使うと HQX / 444 のビット深度・色差が
    /// 先に落ちてしまうため、他の ffmpeg 形式と違って ProRes を中間に使う:
    /// 444 は ProRes 4444(4:4:4)、それ以外は ProRes 422(10ビット 4:2:2)。
    /// どちらも既存 `Exporter` の ProRes 経路で、音声は 24 ビット PCM になる。
    public static func intermediateCodec(for profile: DNxHRProfile) -> String {
        profile == .finishing444 ? OutputPlan.proRes4444 : OutputPlan.proRes422
    }

    /// 中間ファイルの拡張子(ProRes は .mov)。
    public static let intermediateFileExtension = "mov"
}
