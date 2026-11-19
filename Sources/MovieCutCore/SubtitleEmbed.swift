import Foundation
import AVFoundation
import CoreMedia

// MARK: - 設定

/// MP4 書き出しで字幕を字幕トラック(mov_text)として埋め込むかの設定。
/// 既定は無効 = 従来どおり(字幕トラックは作らず、サイドカー出力・映像・音声は無変更)。
public struct SubtitleEmbedSettings: Equatable, Sendable {
    /// 埋め込むときだけ true。
    public var enabled: Bool
    /// 字幕トラックの言語コード(ISO 639-1。トラックには 639-2 の形で記録される)。
    public var languageCode: String

    public init(enabled: Bool = false, languageCode: String = "ja") {
        self.enabled = enabled
        self.languageCode = languageCode.isEmpty ? "ja" : languageCode
    }

    /// 既定(埋め込まない = 従来どおり)。
    public static let disabled = SubtitleEmbedSettings(enabled: false)
    /// 日本語字幕を埋め込む。
    public static let japanese = SubtitleEmbedSettings(enabled: true)
}

// MARK: - 埋め込み字幕の計画と tx3g サンプル

/// MP4 字幕トラック埋め込みの部品。対応経路の実機確認と設計の経緯は docs/MP4字幕埋め込み.md。
///
/// ## 採用経路(2026-11-19、対象 Mac で実機確認)
/// 主経路の `AVAssetWriter` に、書式記述(tx3g)付きのテキスト入力を足す方式を採用した。
/// - 書式記述なしのテキスト入力は `canAdd` が false になる。
/// - 書式記述が素の状態(拡張なし)だと追加はできても `finishWriting` が -11800/-12712 で失敗する。
/// - 拡張(表示フラグ・背景色・テキストボックス・既定スタイル・フォント表)を全部そろえると
///   書き出しが完了し、ffprobe で mov_text(tx3g)トラックとして読め、ffmpeg で SRT に戻しても
///   時刻・日本語テキストが一致することを確認した。既定スタイルとフォント表は必須(欠けると -12715)。
/// - 字幕サンプルの長さは次のサンプルの開始まで伸びてしまうため、件と件の間(と末尾)には
///   空のサンプルを明示的に入れて、終わりの時刻を正確に保つ(ffmpeg の mov_text 出力と同じ並び)。
/// ffmpeg の mov_text エンコーダも対象 Mac で使えることを確認したが、主経路が ffmpeg 不要で
/// 完結するため予備経路としては使わない(本体は「ffmpeg 不要」が原則)。
public enum SubtitleEmbed {
    /// これより短い件・隙間はトラックに入れない(秒)。書き出し範囲の最小長と同じ物差し。
    public static let minDuration = 0.001
    /// tx3g の本文の上限(バイト)。長さは 2 バイトで記録するため 65535 が上限。
    public static let maxTextBytes = 65_535

    // MARK: 件の取り出し(純粋な計算)

    /// 埋め込み用の字幕件: `SubtitleFile.cues(from:)` の件を、書き出し範囲に合わせてずらし・切り詰め、
    /// 本文をサイドカーと同じ作法で整え、重なりは前の件の終わりを次の開始に詰めて解消する。
    /// ルビは mov_text の平文には載せない(親文字だけ)。範囲の外・空の件は出さない。開始順。
    public static func cues(from project: Project, range: ExportRange?) -> [SubtitleCue] {
        let offset = -(range?.start ?? 0)
        let limit = range?.duration ?? project.endTime
        guard limit > 0 else { return [] }
        var out: [SubtitleCue] = []
        for raw in SubtitleFile.cues(from: project) {
            let text = SubtitleFile.cleanBody(raw.text)
            guard !text.isEmpty else { continue }
            var s = raw.start + offset
            var e = raw.end + offset
            guard e > 0, s < limit else { continue }
            s = max(0, s); e = min(limit, e)
            guard e - s >= minDuration else { continue }
            // 重なりは前の件を詰めて解消する(詰めた結果が短すぎる件は落とす)
            while let last = out.last, last.end > s {
                var prev = last
                prev.end = s
                if prev.end - prev.start >= minDuration { out[out.count - 1] = prev; break }
                out.removeLast()
            }
            if let last = out.last, last.end > s { continue }
            out.append(SubtitleCue(start: s, end: e, text: text))
        }
        return out
    }

    /// トラックへ渡すサンプルの並び: 件の後に、隙間(次の件の開始まで。最後の件はトラックの終わりまで)を
    /// 空の件として足す。空サンプルが無いと、読み手が件の表示を次の件まで伸ばしてしまう。
    public static func samples(from cues: [SubtitleCue], trackDuration: Double) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        for (i, c) in cues.enumerated() {
            out.append(c)
            let next = i + 1 < cues.count ? cues[i + 1].start : trackDuration
            let gapEnd = min(next, trackDuration)
            if gapEnd - c.end >= minDuration {
                out.append(SubtitleCue(start: c.end, end: gapEnd, text: ""))
            }
        }
        return out
    }

    // MARK: tx3g のバイト列(純粋な計算)

    /// tx3g サンプルの中身: 2 バイト(ビッグエンディアン)の長さ + UTF-8 の本文。
    /// 上限を超える本文は、文字の途中で切れないよう文字単位で切り詰める。
    public static func tx3gPayload(text: String) -> Data {
        var body = text
        while body.utf8.count > maxTextBytes, !body.isEmpty { body.removeLast() }
        let bytes = Data(body.utf8)
        var payload = Data(capacity: bytes.count + 2)
        payload.append(UInt8((bytes.count >> 8) & 0xff))
        payload.append(UInt8(bytes.count & 0xff))
        payload.append(bytes)
        return payload
    }

    // MARK: AVFoundation の部品

    /// tx3g の書式記述。拡張が 1 つでも欠けると書き出しの最後で失敗するため、実機で確認した組み合わせを全部入れる。
    /// テキストボックスは画面全体、配置は中央・下、文字は白・背景は透明。大きさは画面の高さから決める目安。
    public static func makeFormatDescription(width: Int, height: Int) -> CMFormatDescription? {
        func color(_ r: Int8, _ g: Int8, _ b: Int8, _ a: Int8) -> [String: Any] {
            [kCMTextFormatDescriptionColor_Red as String: r,
             kCMTextFormatDescriptionColor_Green as String: g,
             kCMTextFormatDescriptionColor_Blue as String: b,
             kCMTextFormatDescriptionColor_Alpha as String: a]
        }
        let w = Int16(clamping: width), h = Int16(clamping: height)
        let box: [String: Any] = [
            kCMTextFormatDescriptionRect_Top as String: Int16(0),
            kCMTextFormatDescriptionRect_Left as String: Int16(0),
            kCMTextFormatDescriptionRect_Bottom as String: h,
            kCMTextFormatDescriptionRect_Right as String: w,
        ]
        let fontSize = Int8(clamping: max(12, min(64, height / 20)))
        let style: [String: Any] = [
            kCMTextFormatDescriptionStyle_StartChar as String: Int16(0),
            kCMTextFormatDescriptionStyle_EndChar as String: Int16(0),
            kCMTextFormatDescriptionStyle_Font as String: Int16(1),
            kCMTextFormatDescriptionStyle_FontFace as String: Int8(0),
            kCMTextFormatDescriptionStyle_ForegroundColor as String: color(-1, -1, -1, -1),
            kCMTextFormatDescriptionStyle_FontSize as String: fontSize,
        ]
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: Int32(0),
            // 配置: 横は中央(1)、縦は下(2 = RightOrBottom)
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: Int8(1),
            kCMTextFormatDescriptionExtension_VerticalJustification as String: Int8(2),
            kCMTextFormatDescriptionExtension_BackgroundColor as String: color(0, 0, 0, 0),
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: box,
            kCMTextFormatDescriptionExtension_DefaultStyle as String: style,
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Helvetica"],
        ]
        var fmt: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: kCFAllocatorDefault, mediaType: kCMMediaType_Text,
                                               mediaSubType: kCMTextFormatType_3GText,
                                               extensions: extensions as CFDictionary, formatDescriptionOut: &fmt)
        return status == noErr ? fmt : nil
    }

    /// 1 件分のサンプル。時刻の物差しは 600(映像トラックと同じ)。
    public static func makeSample(format: CMFormatDescription, cue: SubtitleCue) -> CMSampleBuffer? {
        let payload = tx3gPayload(text: cue.text)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: payload.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
                                                 flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let replaced = payload.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard replaced == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: cue.end - cue.start, preferredTimescale: 600),
                                        presentationTimeStamp: CMTime(seconds: cue.start, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let created = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                sampleSizeEntryCount: 1, sampleSizeArray: [payload.count], sampleBufferOut: &sample)
        return created == noErr ? sample : nil
    }
}
