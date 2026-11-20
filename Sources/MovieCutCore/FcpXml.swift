import Foundation

// MARK: - FCP XML(XMEML)交換形式
//
// ## 形式の根拠(推測で書いていない。2026-11-19 に公開資料で確認)
// - Apple 公式「Final Cut Pro XML Interchange Format」(2009-02-04、
//   https://leopard-adc.pepas.com/documentation/AppleApplications/Reference/FinalCutPro_XML/FinalCutPro_XML.pdf)
//   が XMEML バージョン 4 の正資料。要素の意味は同書の Listing と第 5 章に従う:
//   - ルートは `<?xml version="1.0" encoding="UTF-8"?>` + `<!DOCTYPE xmeml>` + `<xmeml version="4">`。
//   - `<sequence>` は name / duration(フレーム数)/ rate / timecode / media を持つ。
//   - `<clipitem>` の start / end はシーケンス内配置(フレーム)、in / out は素材内の使用範囲(フレーム)、
//     duration は out - in。配置がトランジションに依存する箇所は -1(「計算せよ」)で書かれる(Listing 3-17)。
//   - `<file>` の pathurl は `file://localhost/...`(パーセントエンコード済み)。同じ id の空要素は参照。
//   - rate は timebase(整数)+ ntsc フラグ。NTSC レートは 29.97 → timebase 30 / ntsc TRUE のように
//     「公称 timebase + ntsc」で表す(同書 Appendix B)。フレーム数は実レート(30000/1001 等)で数える。
//   - 音量は「Audio Levels」フィルタの Level 引数(線形ゲイン)で表す(同書第 3 章の注記)。
//   - 位置・スケール・回転は「Basic Motion」フィルタ(effectid `basic`、引数 scale=パーセント /
//     rotation=度 / center=horiz・vert)。center の値は同書 Listing の実例(-0.275591 等)に倣い、
//     画面中心を 0 とする割合(幅・高さに対する比率)で書く。不透明度は「Opacity」フィルタ
//     (effectid `opacity`、引数 opacity=0〜100)。
// - Premiere Pro はこの XMEML(FCP 7 XML)を書き出し・読み込みの両方で扱う(fcp.cafe の解説等で確認)。
//   ただし Premiere 独自の拡張要素は本実装では書かない(標準要素のみ)。
//
// ## 第 1 段の対応範囲(詳細は docs/FCPXMLとEDL.md)
// - 書き出し・読み込み共通: カット・配置(トラック分け含む)・素材参照・基本変換(位置/スケール/
//   回転/不透明度)・音量・マーカー・有効/無効。
// - 対応できない要素(キーフレーム、トランジション、エフェクト、文字・ボイス等の素材を持たない
//   クリップ、速度変更ほか)は、黙って落とさずレポートに理由つきで明示する(YmmpExporter と同じ作法)。
// - 他社ソフト(Premiere / Final Cut Pro 7 / DaVinci Resolve)実機での読み込みは未検証。
//   往復(MovieCut → XMEML → MovieCut)の一致までを保証範囲とする。

// MARK: - 共通の小さな道具

/// XMEML の rate(timebase + ntsc)と実フレームレートの対応。
public enum XmemlRate {
    /// MovieCut の fps から XMEML の rate を作る。NTSC 系(分母 1001)は公称 timebase + ntsc TRUE。
    /// timebase が整数で表せないレート(12.5fps 等)は最も近い整数に寄せ、`isApproximate` を立てる
    /// (フレーム数そのものは実レートで数えるので、MovieCut 往復では時刻は保たれる)。
    public static func from(fps: Double) -> (timebase: Int, ntsc: Bool, isApproximate: Bool) {
        let fr = FrameRate.from(fps)
        if fr.den == 1001 {
            // 24000/1001 → 24、30000/1001 → 30 のように公称値へ。
            return (max(1, fr.num / 1000), true, false)
        }
        let nominal = Int(fr.value.rounded())
        let approx = nominal < 1 || abs(Double(nominal) - fr.value) > 0.001
        return (max(1, nominal), false, approx)
    }

    /// XMEML の rate から MovieCut の fps(Double)へ。NTSC の公称値は放送レートの表示値に戻す。
    public static func fps(timebase: Int, ntsc: Bool) -> Double {
        guard ntsc else { return Double(max(1, timebase)) }
        switch timebase {
        case 24: return 23.976
        case 30: return 29.97
        case 48: return 47.952
        case 60: return 59.94
        case 120: return 119.88
        default: return Double(max(1, timebase)) * 1000.0 / 1001.0
        }
    }

    /// ドロップフレーム表記にするレートか(29.97 / 59.94)。
    public static func isDropFrame(timebase: Int, ntsc: Bool) -> Bool {
        ntsc && (timebase == 30 || timebase == 60)
    }
}

enum XmemlText {
    /// XML の要素テキスト用エスケープ。
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// XML の属性値用エスケープ。
    static func escAttr(_ s: String) -> String {
        esc(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 小数の整形(整数は整数、そうでなければ小数 4 桁までで末尾の 0 を落とす)。
    static func num(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// center の horiz / vert 用(割合の細かい値が要るので小数 6 桁まで)。
    static func num6(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// 秒 → フレーム数(実レートで数え、四捨五入)。
    static func frames(_ seconds: Double, fpsValue: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * fpsValue).rounded())
    }

    /// パス → pathurl。絶対パスは `file://localhost` + パーセントエンコード。
    /// 相対パスはそのまま(エンコードのみ)書き、読み込み側もそのまま戻す。
    static func pathURL(for src: String) -> String {
        if src.hasPrefix("file://") { return src }
        let encoded = percentEncodePath(src)
        return src.hasPrefix("/") ? "file://localhost" + encoded : encoded
    }

    /// pathurl → パス。`file://localhost/...` と `file:///...` を剥がしてパーセントデコードする。
    static func path(fromPathURL s: String) -> String {
        var p = s.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("file://localhost") {
            p = String(p.dropFirst("file://localhost".count))
        } else if p.hasPrefix("file://") {
            p = String(p.dropFirst("file://".count))
            if !p.hasPrefix("/") {
                // file://host/path の host 部分を落とす。
                if let idx = p.firstIndex(of: "/") { p = String(p[idx...]) }
            }
        }
        return p.removingPercentEncoding ?? p
    }

    /// パスのパーセントエンコード(英数字と `-._~/` 以外を UTF-8 バイトごとに %XX にする)。
    static func percentEncodePath(_ path: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/".utf8)
        var out = ""
        for b in path.utf8 {
            if allowed.contains(b) {
                out.unicodeScalars.append(UnicodeScalar(b))
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    /// 素材ファイルの表示名(パスの最後の要素)。パスが空なら既定の名前。
    static func displayName(for src: String?) -> String {
        guard let src, !src.isEmpty else { return "素材なしクリップ" }
        let last = (src as NSString).lastPathComponent
        return last.isEmpty ? src : last
    }

    static let stillImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "bmp", "heic", "heif"]

    static func isStillImagePath(_ src: String) -> Bool {
        stillImageExtensions.contains((src as NSString).pathExtension.lowercased())
    }
}

// MARK: - 書き出し

/// MovieCut の `Project` を FCP XML(XMEML バージョン 4)へ書き出すエクスポーター。
public enum FcpXmlExporter {

    // MARK: レポート(YmmpExporter と同じ形)

    /// クリップごと書き出せなかったもの。
    public struct Unsupported: Equatable {
        public var typeName: String
        public var label: String
        public var reason: String
        public init(typeName: String, label: String, reason: String) {
            self.typeName = typeName; self.label = label; self.reason = reason
        }
    }

    /// クリップ自体は書き出せたが、一部の機能・値が落ちたもの。
    public struct DroppedFeature: Equatable {
        public var label: String
        public var feature: String
        public var reason: String
        public init(label: String, feature: String, reason: String) {
            self.label = label; self.feature = feature; self.reason = reason
        }
    }

    /// 書き出しレポート。何が書けて、何が落ちたかを呼び出し側(UI / CLI)が利用者に見せるためのもの。
    public struct Report: Equatable {
        public var convertedCounts: [String: Int] = [:]
        public var unsupported: [Unsupported] = []
        public var droppedFeatures: [DroppedFeature] = []
        public var notes: [String] = []
        public init() {}
        public var convertedCount: Int { convertedCounts.values.reduce(0, +) }
        public var hasLoss: Bool { !unsupported.isEmpty || !droppedFeatures.isEmpty }
        public var summaryLines: [String] {
            var lines = [String(format: L10n.t("書き出し: %d 件"), convertedCount)]
            for u in unsupported { lines.append(String(format: L10n.t("書き出せませんでした [%@] %@: %@"), u.typeName, u.label, L10n.t(u.reason))) }
            for d in droppedFeatures { lines.append(String(format: L10n.t("一部のみ書き出し %@: %@(%@)"), d.label, L10n.t(d.feature), L10n.t(d.reason))) }
            for n in notes { lines.append(String(format: L10n.t("注記: %@"), L10n.t(n))) }
            return lines
        }
    }

    /// 書き出し結果(XML 文字列とレポート)。
    public struct Output {
        public var xml: String
        public var report: Report
        public init(xml: String, report: Report) { self.xml = xml; self.report = report }
    }

    // MARK: 入口

    /// プロジェクトを XMEML 文字列にする。元のプロジェクトは変更しない。
    public static func export(project: Project, sequenceName: String = "メイン") -> Output {
        var report = Report()
        var builder = Builder(project: project, report: &report)
        let xml = builder.build(sequenceName: sequenceName)
        report = builder.report
        return Output(xml: xml, report: report)
    }

    /// プロジェクトを `.xml` ファイルに書く。レポートを返す(落ちた要素の確認用)。
    @discardableResult
    public static func write(project: Project, to url: URL, sequenceName: String = "メイン") throws -> Report {
        let out = export(project: project, sequenceName: sequenceName)
        try out.xml.write(to: url, atomically: true, encoding: .utf8)
        return out.report
    }

    // MARK: 変換の本体

    private struct FileDef {
        var id: String
        var src: String
        var isAudio: Bool
        var emittedFull = false
    }

    private struct Builder {
        var project: Project
        var report: Report
        var lines: [String] = []
        var fileDefs: [String: FileDef] = [:]   // キー: src + 種別
        var fileOrder: [String] = []
        var fileCounter = 0
        var notedFileDuration = false
        var notedVideoAudio = false

        let rate: (timebase: Int, ntsc: Bool, isApproximate: Bool)
        let fpsValue: Double

        init(project: Project, report: inout Report) {
            self.project = project
            self.report = report
            self.rate = XmemlRate.from(fps: project.fps)
            self.fpsValue = project.frameRate.value
        }

        mutating func line(_ level: Int, _ s: String) {
            lines.append(String(repeating: "  ", count: level) + s)
        }

        mutating func build(sequenceName: String) -> String {
            // トラックの振り分け: MovieCut のレイヤーは映像・音声が混ざりうるので、
            // XMEML の映像トラック列と音声トラック列へ分ける(それぞれ元の順序を保つ)。
            var videoTracks: [(track: Track, clips: [Clip])] = []
            var audioTracks: [(track: Track, clips: [Clip])] = []
            for track in project.tracks {
                var visual: [Clip] = []
                var audio: [Clip] = []
                for clip in track.clips {
                    switch clip.type {
                    case .video, .image: visual.append(clip)
                    case .audio: audio.append(clip)
                    default:
                        report.unsupported.append(Unsupported(
                            typeName: clip.type.rawValue,
                            label: Self.clipLabel(clip),
                            reason: "XMEML で表せる素材クリップ(映像・画像・音声)ではないため"))
                    }
                }
                if !visual.isEmpty { videoTracks.append((track, visual)) }
                if !audio.isEmpty { audioTracks.append((track, audio)) }
            }

            // シーケンスの長さ(書き出すクリップの終わりの最大)。
            var totalFrames = 0
            for t in videoTracks + audioTracks {
                for c in t.clips { totalFrames = max(totalFrames, XmemlText.frames(c.start + c.duration, fpsValue: fpsValue)) }
            }

            if rate.isApproximate {
                report.notes.append("フレームレート \(FrameRate.label(project.fps))fps は XMEML の整数 timebase で正確に表せないため、timebase \(rate.timebase) として書きました(フレーム数は実レートで数えています)")
            }
            if !notedVideoAudio {
                // 動画クリップの音は映像側に付随するものとして扱う旨は、動画があるときだけ注記する。
                if videoTracks.contains(where: { $0.clips.contains { $0.type == .video } }) {
                    report.notes.append("動画クリップの音声は映像クリップに付随するものとして書き出しました(音声だけを分けた linked な音声 clipitem は第 1 段では出しません)")
                    notedVideoAudio = true
                }
            }

            lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
            lines.append("<!DOCTYPE xmeml>")
            lines.append("<xmeml version=\"4\">")
            line(1, "<sequence id=\"\(XmemlText.escAttr(sequenceName))\">")
            line(2, "<name>\(XmemlText.esc(sequenceName))</name>")
            line(2, "<duration>\(totalFrames)</duration>")
            rateLines(level: 2)
            timecodeLines(level: 2)
            line(2, "<media>")
            // 映像
            line(3, "<video>")
            line(4, "<format>")
            line(5, "<samplecharacteristics>")
            rateLines(level: 6)
            line(6, "<width>\(project.width)</width>")
            line(6, "<height>\(project.height)</height>")
            line(6, "<anamorphic>FALSE</anamorphic>")
            line(6, "<pixelaspectratio>square</pixelaspectratio>")
            line(6, "<fielddominance>none</fielddominance>")
            line(6, "<colordepth>24</colordepth>")
            line(5, "</samplecharacteristics>")
            line(4, "</format>")
            for t in videoTracks { trackLines(t.track, clips: t.clips, isAudio: false) }
            line(3, "</video>")
            // 音声
            line(3, "<audio>")
            line(4, "<format>")
            line(5, "<samplecharacteristics>")
            line(6, "<depth>16</depth>")
            line(6, "<samplerate>48000</samplerate>")
            line(5, "</samplecharacteristics>")
            line(4, "</format>")
            line(4, "<outputs>")
            line(5, "<group>")
            line(6, "<index>1</index>")
            line(6, "<numchannels>2</numchannels>")
            line(6, "<downmix>0</downmix>")
            line(6, "<channel><index>1</index></channel>")
            line(6, "<channel><index>2</index></channel>")
            line(5, "</group>")
            line(4, "</outputs>")
            for t in audioTracks { trackLines(t.track, clips: t.clips, isAudio: true) }
            line(3, "</audio>")
            line(2, "</media>")
            markerLines()
            line(1, "</sequence>")
            lines.append("</xmeml>")
            return lines.joined(separator: "\n") + "\n"
        }

        mutating func rateLines(level: Int) {
            line(level, "<rate>")
            line(level + 1, "<timebase>\(rate.timebase)</timebase>")
            line(level + 1, "<ntsc>\(rate.ntsc ? "TRUE" : "FALSE")</ntsc>")
            line(level, "</rate>")
        }

        mutating func timecodeLines(level: Int) {
            let df = XmemlRate.isDropFrame(timebase: rate.timebase, ntsc: rate.ntsc)
            line(level, "<timecode>")
            line(level + 1, "<rate>")
            line(level + 2, "<timebase>\(rate.timebase)</timebase>")
            line(level + 2, "<ntsc>\(rate.ntsc ? "TRUE" : "FALSE")</ntsc>")
            line(level + 1, "</rate>")
            line(level + 1, "<string>00:00:00:00</string>")
            line(level + 1, "<frame>0</frame>")
            line(level + 1, "<displayformat>\(df ? "DF" : "NDF")</displayformat>")
            line(level, "</timecode>")
        }

        mutating func markerLines() {
            for m in project.markers.sorted(by: { $0.time < $1.time }) {
                let f = XmemlText.frames(m.time, fpsValue: fpsValue)
                line(2, "<marker>")
                line(3, "<name>\(XmemlText.esc(m.name))</name>")
                line(3, "<in>\(f)</in>")
                line(3, "<out>\(f)</out>")
                line(2, "</marker>")
            }
            if project.markers.contains(where: { $0.color != nil }) {
                report.notes.append("マーカーの色は XMEML に表す場所がないため書き出していません")
            }
        }

        mutating func trackLines(_ track: Track, clips: [Clip], isAudio: Bool) {
            line(4, "<track>")
            for clip in clips.sorted(by: { $0.start < $1.start }) {
                clipItemLines(clip, isAudio: isAudio)
            }
            let enabled = isAudio ? !track.isMuted : !track.isHidden
            line(5, "<enabled>\(enabled ? "TRUE" : "FALSE")</enabled>")
            line(5, "<locked>\(track.isLocked ? "TRUE" : "FALSE")</locked>")
            line(4, "</track>")
        }

        static func clipLabel(_ clip: Clip) -> String {
            if let src = clip.src, !src.isEmpty { return XmemlText.displayName(for: src) }
            if let text = clip.text, !text.isEmpty { return String(text.prefix(20)) }
            return "\(clip.type.rawValue) クリップ"
        }

        mutating func clipItemLines(_ clip: Clip, isAudio: Bool) {
            let label = Self.clipLabel(clip)
            report.convertedCounts[clip.type.rawValue, default: 0] += 1
            noteDroppedFeatures(of: clip, label: label, isAudio: isAudio)

            let startF = XmemlText.frames(clip.start, fpsValue: fpsValue)
            let endF = XmemlText.frames(clip.start + clip.duration, fpsValue: fpsValue)
            let inF = XmemlText.frames(clip.offset, fpsValue: fpsValue)
            // 速度は第 1 段では運ばないため、out - in == end - start(等倍の範囲)にそろえる。
            let outF = inF + max(0, endF - startF)
            let name = XmemlText.displayName(for: clip.src)

            line(5, "<clipitem id=\"\(XmemlText.escAttr(clip.id))\">")
            line(6, "<name>\(XmemlText.esc(name))</name>")
            line(6, "<duration>\(max(0, outF - inF))</duration>")
            rateLines(level: 6)
            line(6, "<start>\(startF)</start>")
            line(6, "<end>\(endF)</end>")
            line(6, "<in>\(inF)</in>")
            line(6, "<out>\(outF)</out>")
            let disabled = clip.isDisabled || (isAudio && clip.isMuted)
            if disabled { line(6, "<enabled>FALSE</enabled>") }
            if let src = clip.src, !src.isEmpty {
                fileLines(src: src, isAudio: isAudio, fallbackDurationFrames: outF)
            } else {
                report.notes.append("クリップ「\(label)」には素材の参照がないため、file のない clipitem として書き出しました")
            }
            line(6, "<sourcetrack>")
            line(7, "<mediatype>\(isAudio ? "audio" : "video")</mediatype>")
            line(7, "<trackindex>1</trackindex>")
            line(6, "</sourcetrack>")
            if !isAudio {
                basicMotionLines(clip)
                opacityLines(clip)
            } else if clip.volumeOrDefault != 1 {
                audioLevelsLines(clip)
            }
            line(5, "</clipitem>")
        }

        /// 同じ素材は最初の 1 回だけ完全な file を書き、以降は id 参照だけにする(仕様の継承の作法)。
        mutating func fileLines(src: String, isAudio: Bool, fallbackDurationFrames: Int) {
            let key = (isAudio ? "a:" : "v:") + src
            if var def = fileDefs[key] {
                if def.emittedFull {
                    line(6, "<file id=\"\(XmemlText.escAttr(def.id))\"/>")
                    return
                }
                def.emittedFull = true
                fileDefs[key] = def
            } else {
                fileCounter += 1
                let def = FileDef(id: "file\(fileCounter)", src: src, isAudio: isAudio, emittedFull: true)
                fileDefs[key] = def
                fileOrder.append(key)
            }
            let def = fileDefs[key]!
            let durationFrames: Int
            if let sd = clipSrcDuration(src: src) {
                durationFrames = XmemlText.frames(sd, fpsValue: fpsValue)
            } else {
                durationFrames = fallbackDurationFrames
                if !notedFileDuration {
                    report.notes.append("素材の長さ(srcDuration)が分からない素材は、使用範囲の終わりを素材の長さとして書きました")
                    notedFileDuration = true
                }
            }
            line(6, "<file id=\"\(XmemlText.escAttr(def.id))\">")
            line(7, "<name>\(XmemlText.esc(XmemlText.displayName(for: src)))</name>")
            line(7, "<pathurl>\(XmemlText.esc(XmemlText.pathURL(for: src)))</pathurl>")
            rateLines(level: 7)
            line(7, "<duration>\(durationFrames)</duration>")
            line(7, "<timecode>")
            line(8, "<rate>")
            line(9, "<timebase>\(rate.timebase)</timebase>")
            line(9, "<ntsc>\(rate.ntsc ? "TRUE" : "FALSE")</ntsc>")
            line(8, "</rate>")
            line(8, "<string>00:00:00:00</string>")
            line(8, "<frame>0</frame>")
            line(8, "<displayformat>NDF</displayformat>")
            line(7, "</timecode>")
            line(7, "<media>")
            if isAudio {
                line(8, "<audio>")
                line(9, "<samplecharacteristics>")
                line(10, "<depth>16</depth>")
                line(10, "<samplerate>48000</samplerate>")
                line(9, "</samplecharacteristics>")
                line(9, "<channelcount>2</channelcount>")
                line(8, "</audio>")
            } else {
                line(8, "<video>")
                line(9, "<samplecharacteristics>")
                line(10, "<width>\(project.width)</width>")
                line(10, "<height>\(project.height)</height>")
                line(9, "</samplecharacteristics>")
                line(8, "</video>")
            }
            line(7, "</media>")
            line(6, "</file>")
        }

        /// 素材の長さは、プロジェクト内でその素材を使うクリップの srcDuration から引く。
        func clipSrcDuration(src: String) -> Double? {
            for track in project.tracks {
                for clip in track.clips where clip.src == src {
                    if let sd = clip.srcDuration, sd > 0 { return sd }
                }
            }
            return nil
        }

        mutating func basicMotionLines(_ clip: Clip) {
            let hasScale = clip.scaleOrDefault != 1
            let hasRotation = clip.rotationOrDefault != 0
            let hasCenter = clip.xOrDefault != 0.5 || clip.yOrDefault != 0.5
            guard hasScale || hasRotation || hasCenter else { return }
            line(6, "<filter>")
            line(7, "<start>-1</start>")
            line(7, "<end>-1</end>")
            line(7, "<effect>")
            line(8, "<name>Basic Motion</name>")
            line(8, "<effectid>basic</effectid>")
            line(8, "<effectcategory>motion</effectcategory>")
            line(8, "<effecttype>motion</effecttype>")
            line(8, "<mediatype>video</mediatype>")
            if hasScale {
                line(8, "<parameter>")
                line(9, "<parameterid>scale</parameterid>")
                line(9, "<name>Scale</name>")
                line(9, "<valuemin>0</valuemin>")
                line(9, "<valuemax>1000</valuemax>")
                line(9, "<value>\(XmemlText.num(clip.scaleOrDefault * 100))</value>")
                line(8, "</parameter>")
            }
            if hasRotation {
                line(8, "<parameter>")
                line(9, "<parameterid>rotation</parameterid>")
                line(9, "<name>Rotation</name>")
                line(9, "<valuemin>-100000</valuemin>")
                line(9, "<valuemax>100000</valuemax>")
                line(9, "<value>\(XmemlText.num(clip.rotationOrDefault))</value>")
                line(8, "</parameter>")
            }
            if hasCenter {
                line(8, "<parameter>")
                line(9, "<parameterid>center</parameterid>")
                line(9, "<name>Center</name>")
                line(9, "<value>")
                line(10, "<horiz>\(XmemlText.num6(clip.xOrDefault - 0.5))</horiz>")
                line(10, "<vert>\(XmemlText.num6(clip.yOrDefault - 0.5))</vert>")
                line(9, "</value>")
                line(8, "</parameter>")
            }
            line(7, "</effect>")
            line(6, "</filter>")
        }

        mutating func opacityLines(_ clip: Clip) {
            guard clip.opacityOrDefault != 1 else { return }
            let pct = min(max(clip.opacityOrDefault, 0), 1) * 100
            line(6, "<filter>")
            line(7, "<start>-1</start>")
            line(7, "<end>-1</end>")
            line(7, "<effect>")
            line(8, "<name>Opacity</name>")
            line(8, "<effectid>opacity</effectid>")
            line(8, "<effectcategory>composite</effectcategory>")
            line(8, "<effecttype>filter</effecttype>")
            line(8, "<mediatype>video</mediatype>")
            line(8, "<parameter>")
            line(9, "<parameterid>opacity</parameterid>")
            line(9, "<name>Opacity</name>")
            line(9, "<valuemin>0</valuemin>")
            line(9, "<valuemax>100</valuemax>")
            line(9, "<value>\(XmemlText.num(pct))</value>")
            line(8, "</parameter>")
            line(7, "</effect>")
            line(6, "</filter>")
        }

        mutating func audioLevelsLines(_ clip: Clip) {
            line(6, "<filter>")
            line(7, "<start>-1</start>")
            line(7, "<end>-1</end>")
            line(7, "<effect>")
            line(8, "<name>Audio Levels</name>")
            line(8, "<effectid>audiolevels</effectid>")
            line(8, "<effectcategory>audio</effectcategory>")
            line(8, "<effecttype>filter</effecttype>")
            line(8, "<mediatype>audio</mediatype>")
            line(8, "<parameter>")
            line(9, "<parameterid>level</parameterid>")
            line(9, "<name>Level</name>")
            line(9, "<valuemin>0</valuemin>")
            line(9, "<valuemax>4</valuemax>")
            line(9, "<value>\(XmemlText.num(clip.volumeOrDefault))</value>")
            line(8, "</parameter>")
            line(7, "</effect>")
            line(6, "</filter>")
        }

        /// 書き出せない・落ちる要素をレポートへ。黙って落とさないための要。
        mutating func noteDroppedFeatures(of clip: Clip, label: String, isAudio: Bool) {
            func drop(_ feature: String, _ reason: String) {
                report.droppedFeatures.append(DroppedFeature(label: label, feature: feature, reason: reason))
            }
            if !clip.keyframes.isEmpty {
                drop("キーフレーム", "第 1 段では静止値だけを書き出します")
            }
            if let t = clip.transitionIn { drop("入トランジション(\(t.kind))", "XMEML の transitionitem はクリップ間の重なりを前提とし、MovieCut の入/出トランジションとは形が違うため") }
            if let t = clip.transitionOut { drop("出トランジション(\(t.kind))", "XMEML の transitionitem はクリップ間の重なりを前提とし、MovieCut の入/出トランジションとは形が違うため") }
            if !clip.effects.isEmpty { drop("エフェクト \(clip.effects.count) 件", "他社ソフトと共通の表現がないため") }
            if clip.audioFx != nil { drop("音声エフェクト", "他社ソフトと共通の表現がないため") }
            if clip.fadeInOrDefault > 0 || clip.fadeOutOrDefault > 0 { drop("音声フェード", "第 1 段では運びません") }
            if clip.hasTimeRemap { drop("速度変更・逆再生・フリーズ", "第 1 段では速度を運ばず、等倍の使用範囲として書き出します") }
            if !isAudio {
                if let crop = clip.crop, !crop.isEmpty { drop("切り抜き", "第 1 段では運びません") }
                if clip.flipHOrDefault || clip.flipVOrDefault { drop("反転", "第 1 段では運びません") }
                if clip.blendMode != nil { drop("ブレンドモード", "XMEML の compositemode との対応が未検証のため") }
                if clip.mask != nil { drop("形のマスク", "第 1 段では運びません") }
                if clip.meshWarp != nil || clip.puppetWarp != nil { drop("メッシュ/パペット変形", "他社ソフトと共通の表現がないため") }
            } else {
                if let pan = clip.pan, pan != 0 { drop("パン", "第 1 段では運びません") }
            }
            if clip.type == .video, clip.volume != nil || clip.audioFx != nil {
                // 音量そのものは映像側では運ばない(音声を分けない方針のため)。
                if clip.volume != nil { drop("動画クリップの音量", "音声を分けた clipitem を出さない方針のため") }
            }
        }
    }
}

// MARK: - 読み込み

/// FCP XML(XMEML)文字列を MovieCut の `Project` へ変換するインポーター。
public enum FcpXmlImporter {

    /// 読み込みで取りこぼした要素。
    public struct Unsupported: Equatable {
        public var element: String
        public var label: String
        public var reason: String
        public init(element: String, label: String, reason: String) {
            self.element = element; self.label = label; self.reason = reason
        }
    }

    /// 読み込みレポート。
    public struct Report: Equatable {
        public var convertedCounts: [String: Int] = [:]
        public var unsupported: [Unsupported] = []
        public var notes: [String] = []
        public init() {}
        public var convertedCount: Int { convertedCounts.values.reduce(0, +) }
        public var hasLoss: Bool { !unsupported.isEmpty }
        public var summaryLines: [String] {
            var lines = [String(format: L10n.t("読み込み: %d 件"), convertedCount)]
            for u in unsupported { lines.append(String(format: L10n.t("読み込めませんでした [%@] %@: %@"), u.element, u.label, L10n.t(u.reason))) }
            for n in notes { lines.append(String(format: L10n.t("注記: %@"), L10n.t(n))) }
            return lines
        }
    }

    /// 読み込み結果。
    public struct Output {
        public var project: Project
        public var report: Report
        public init(project: Project, report: Report) { self.project = project; self.report = report }
    }

    public enum ImportError: Error, LocalizedError {
        case malformedXML(String)
        case notXmeml
        case noSequence
        case noMedia

        public var errorDescription: String? {
            switch self {
            case .malformedXML(let detail): return "XML として読めませんでした: \(detail)"
            case .notXmeml: return "FCP XML(XMEML)ではありません(xmeml 要素がありません。FCPXML とは別形式です)"
            case .noSequence: return "シーケンスが見つかりませんでした"
            case .noMedia: return "シーケンスに media が見つかりませんでした"
            }
        }
    }

    // MARK: 入口

    /// XMEML 文字列をプロジェクトへ変換する。
    public static func parse(xml: String) throws -> Output {
        guard let data = xml.data(using: .utf8) else { throw ImportError.malformedXML("UTF-8 に変換できません") }
        return try parse(data: data)
    }

    /// XMEML データをプロジェクトへ変換する。
    public static func parse(data: Data) throws -> Output {
        let builder = XmlTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            throw ImportError.malformedXML(parser.parserError?.localizedDescription ?? "解析に失敗しました")
        }
        guard root.name == "xmeml" else { throw ImportError.notXmeml }
        var converter = Converter(root: root)
        return try converter.convert()
    }

    /// ファイルから読み込む。
    public static func read(from url: URL) throws -> Output {
        let data = try InputLimits.readFile(url, limit: InputLimits.maxFcpXmlBytes, what: "FCPXML")
        return try parse(data: data)
    }

    // MARK: XML の木(XMLParser の受け皿)

    final class XmlNode {
        let name: String
        var attributes: [String: String] = [:]
        var children: [XmlNode] = []
        var text = ""
        init(name: String) { self.name = name }
        func first(_ n: String) -> XmlNode? { children.first { $0.name == n } }
        func all(_ n: String) -> [XmlNode] { children.filter { $0.name == n } }
        func str(_ n: String) -> String? {
            guard let v = first(n)?.text.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        func int(_ n: String) -> Int? { str(n).flatMap { Int($0) } }
        func dbl(_ n: String) -> Double? { str(n).flatMap { Double($0) } }
        func bool(_ n: String) -> Bool? {
            guard let v = str(n) else { return nil }
            return v.uppercased() == "TRUE"
        }
    }

    final class XmlTreeBuilder: NSObject, XMLParserDelegate {
        var root: XmlNode?
        private var stack: [XmlNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = XmlNode(name: elementName)
            node.attributes = attributeDict
            if let parent = stack.last { parent.children.append(node) }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if let node = stack.popLast(), stack.isEmpty { root = node }
        }
    }

    // MARK: 変換の本体

    private struct Converter {
        var root: XmlNode
        var report = Report()
        /// file の id → (パス, 名前, 素材の長さフレーム)。clipitem 内の完全な file 定義から集める。
        var fileDefs: [String: (src: String?, name: String?, durationFrames: Int?)] = [:]

        mutating func convert() throws -> Output {
            if let v = root.attributes["version"], !["1", "2", "3", "4", "5"].contains(v) {
                report.notes.append("XMEML バージョン \(v) は想定外ですが、読める範囲で読み込みます")
            }
            guard let sequence = findSequence() else { throw ImportError.noSequence }
            guard let media = sequence.first("media") else { throw ImportError.noMedia }

            // レート(シーケンス優先、無ければ format 側)。
            var timebase = 30
            var ntsc = false
            if let r = sequence.first("rate") {
                timebase = r.int("timebase") ?? timebase
                ntsc = r.bool("ntsc") ?? false
            } else if let r = media.first("video")?.first("format")?.first("samplecharacteristics")?.first("rate") {
                timebase = r.int("timebase") ?? timebase
                ntsc = r.bool("ntsc") ?? false
            } else {
                report.notes.append("レート情報がないため 30fps として読み込みました")
            }
            let fps = XmemlRate.fps(timebase: timebase, ntsc: ntsc)
            let fpsValue = FrameRate.from(fps).value
            func seconds(_ frames: Int) -> Double { Double(frames) / fpsValue }

            // 画面サイズ(format 優先、無ければ file の media、最後は 1920×1080)。
            var width = media.first("video")?.first("format")?.first("samplecharacteristics")?.int("width")
            var height = media.first("video")?.first("format")?.first("samplecharacteristics")?.int("height")
            if width == nil || height == nil {
                report.notes.append("シーケンスの画面サイズが分からないため 1920×1080 として読み込みました")
                width = width ?? 1920
                height = height ?? 1080
            }

            collectFileDefs(in: sequence)

            var project = Project()
            project.width = width ?? 1920
            project.height = height ?? 1080
            project.fps = fps

            var tracks: [Track] = []
            var pool: [String] = []
            let video = media.first("video")
            let audio = media.first("audio")
            for (i, trackNode) in (video?.all("track") ?? []).enumerated() {
                var track = Track(name: "V\(i + 1)")
                track.clips = convertTrack(trackNode, isAudio: false, seconds: seconds, pool: &pool)
                if trackNode.bool("enabled") == false { track.hidden = true }
                tracks.append(track)
            }
            for (i, trackNode) in (audio?.all("track") ?? []).enumerated() {
                var track = Track(name: "A\(i + 1)")
                track.clips = convertTrack(trackNode, isAudio: true, seconds: seconds, pool: &pool)
                if trackNode.bool("enabled") == false { track.muted = true }
                tracks.append(track)
            }
            if tracks.isEmpty {
                report.notes.append("トラックがありませんでした")
                tracks = Track.defaultLayers()
            }
            project.tracks = tracks
            project.mediaPool = pool

            for markerNode in sequence.all("marker") {
                let f = markerNode.int("in") ?? 0
                project.markers.append(Marker(time: seconds(f), name: markerNode.str("name") ?? ""))
            }
            if let name = sequence.str("name") {
                report.notes.append("シーケンス「\(name)」を読み込みました")
            }
            return Output(project: project, report: report)
        }

        func findSequence() -> XmlNode? {
            if let s = root.first("sequence") { return s }
            // <project><children>…</children></project> の中を探す(最大で bin の 1 段まで)。
            guard let children = root.first("project")?.first("children") else { return nil }
            if let s = children.first("sequence") { return s }
            for bin in children.all("bin") {
                if let s = bin.first("children")?.first("sequence") { return s }
            }
            return nil
        }

        mutating func collectFileDefs(in sequence: XmlNode) {
            func walk(_ node: XmlNode) {
                if node.name == "file", let id = node.attributes["id"] {
                    if let pathurl = node.str("pathurl") {
                        fileDefs[id] = (XmemlText.path(fromPathURL: pathurl), node.str("name"), node.int("duration"))
                    } else if node.str("name") != nil, fileDefs[id] == nil {
                        fileDefs[id] = (nil, node.str("name"), node.int("duration"))
                    }
                }
                for c in node.children { walk(c) }
            }
            walk(sequence)
        }

        /// トラック内の項目列を、-1(計算せよ)を前後の項目とトランジションから解決しながら変換する。
        mutating func convertTrack(_ trackNode: XmlNode, isAudio: Bool, seconds: (Int) -> Double, pool: inout [String]) -> [Clip] {
            // まず生の項目列(clipitem / transitionitem / generatoritem)を並べる。
            struct Raw {
                var kind: String
                var node: XmlNode
                var start: Int?
                var end: Int?
                var duration: Int?
            }
            var raws: [Raw] = []
            for child in trackNode.children where ["clipitem", "transitionitem", "generatoritem"].contains(child.name) {
                raws.append(Raw(kind: child.name, node: child,
                                 start: child.int("start"), end: child.int("end"), duration: child.int("duration")))
            }
            var clips: [Clip] = []
            for (idx, raw) in raws.enumerated() {
                switch raw.kind {
                case "transitionitem":
                    let effectName = raw.node.first("effect")?.str("name") ?? "トランジション"
                    report.unsupported.append(Unsupported(element: "transitionitem", label: effectName,
                                                          reason: "トランジションは第 1 段では読み込まず、カットとして扱いました"))
                case "generatoritem":
                    let label = raw.node.str("name") ?? "ジェネレータ"
                    report.unsupported.append(Unsupported(element: "generatoritem", label: label,
                                                          reason: "ジェネレータ(文字等)は第 1 段では読み込んでいません"))
                case "clipitem":
                    // 配置の解決: -1 / 欠落は前後のトランジション・直前のクリップから補う(仕様 Listing 3-17)。
                    var resolvedStart = raw.start
                    if resolvedStart == nil || resolvedStart == -1 {
                        if idx > 0, raws[idx - 1].kind == "transitionitem", let ts = raws[idx - 1].start, ts != -1 {
                            resolvedStart = ts
                        } else if let prev = clips.last {
                            resolvedStart = Int(((prev.start + prev.duration) / max(seconds(1), 0.000001)).rounded())
                        } else {
                            resolvedStart = 0
                        }
                    }
                    var resolvedEnd = raw.end
                    if resolvedEnd == nil || resolvedEnd == -1 {
                        if idx + 1 < raws.count, raws[idx + 1].kind == "transitionitem", let te = raws[idx + 1].end, te != -1 {
                            resolvedEnd = te
                        } else if let s = resolvedStart, let d = raw.duration {
                            resolvedEnd = s + d
                        } else {
                            resolvedEnd = resolvedStart
                        }
                    }
                    if let clip = convertClipItem(raw.node, isAudio: isAudio,
                                                  startFrames: resolvedStart ?? 0, endFrames: resolvedEnd ?? (resolvedStart ?? 0),
                                                  seconds: seconds, pool: &pool) {
                        clips.append(clip)
                    }
                default:
                    break
                }
            }
            return clips
        }

        mutating func convertClipItem(_ node: XmlNode, isAudio: Bool, startFrames: Int, endFrames: Int,
                                      seconds: (Int) -> Double, pool: inout [String]) -> Clip? {
            let label = node.str("name") ?? "クリップ"
            if node.first("sequence") != nil {
                report.unsupported.append(Unsupported(element: "clipitem(sequence)", label: label,
                                                      reason: "入れ子のシーケンスは第 1 段では読み込んでいません"))
                return nil
            }
            var clip = Clip()
            // 素材参照(file の完全定義か id 参照を解決する)。
            var src: String? = nil
            if let fileNode = node.first("file") {
                if let pathurl = fileNode.str("pathurl") {
                    src = XmemlText.path(fromPathURL: pathurl)
                } else if let id = fileNode.attributes["id"], let def = fileDefs[id] {
                    src = def.src
                }
            }
            clip.src = src
            if let src, !src.isEmpty, !pool.contains(src) { pool.append(src) }
            if src == nil {
                report.notes.append("クリップ「\(label)」には素材の参照がないため、参照なしのクリップとして読み込みました")
            }
            if isAudio {
                clip.type = .audio
            } else if let src, XmemlText.isStillImagePath(src) {
                clip.type = .image
            } else {
                clip.type = .video
            }
            clip.start = seconds(startFrames)
            clip.duration = max(0, seconds(endFrames) - seconds(startFrames))
            let inFrames = node.int("in") ?? 0
            clip.offset = seconds(max(0, inFrames))
            if let fileNode = node.first("file"), let fd = fileNode.int("duration") {
                clip.srcDuration = seconds(fd)
            } else if let id = node.first("file")?.attributes["id"], let def = fileDefs[id], let fd = def.durationFrames {
                clip.srcDuration = seconds(fd)
            }
            if node.bool("enabled") == false { clip.disabled = true }
            applyFilters(node, to: &clip, label: label)
            report.convertedCounts[clip.type.rawValue, default: 0] += 1
            return clip
        }

        /// Basic Motion / Opacity / Audio Levels を静止値として取り込む。その他のエフェクトはレポートへ。
        mutating func applyFilters(_ node: XmlNode, to clip: inout Clip, label: String) {
            for filterNode in node.all("filter") {
                guard let effect = filterNode.first("effect") else { continue }
                let effectId = (effect.str("effectid") ?? "").lowercased()
                let effectName = effect.str("name") ?? effectId
                var params: [String: XmlNode] = [:]
                for p in effect.all("parameter") {
                    if let pid = p.str("parameterid") { params[pid.lowercased()] = p }
                }
                func value(_ pid: String) -> Double? {
                    guard let p = params[pid] else { return nil }
                    if let v = p.first("value") {
                        if let d = Double(v.text.trimmingCharacters(in: .whitespacesAndNewlines)) { return d }
                        return nil
                    }
                    if !p.all("keyframe").isEmpty {
                        report.notes.append("クリップ「\(label)」の \(pid) にはキーフレームがありました。第 1 段では先頭の値を静止値として読み込みます")
                        if let first = p.all("keyframe").first, let d = first.dbl("value") { return d }
                    }
                    return nil
                }
                switch effectId {
                case "basic":
                    if let v = value("scale") { clip.scale = v / 100 }
                    if let v = value("rotation") { clip.rotation = v == 0 ? nil : v }
                    if let center = params["center"]?.first("value"),
                       let h = center.dbl("horiz"), let v = center.dbl("vert") {
                        clip.x = h + 0.5
                        clip.y = v + 0.5
                    }
                case "opacity":
                    if let v = value("opacity") { clip.opacity = min(max(v / 100, 0), 1) }
                case "audiolevels", "audio levels":
                    if let v = value("level") { clip.volume = v }
                default:
                    if !effectId.isEmpty || !effectName.isEmpty {
                        report.unsupported.append(Unsupported(element: "filter", label: label,
                                                              reason: "エフェクト「\(effectName)」は対応していないため読み込んでいません"))
                    }
                }
            }
        }
    }
}
