import Foundation

// MARK: - EDL(CMX 3600)書き出し
//
// ## 形式の根拠(推測で書いていない。2026-11-19 に公開資料で確認)
// - CMX 3600 は CMX Systems の編集コントローラ由来の EDL(編集決定リスト)形式で、
//   SMPTE 258M として標準化された事実上の共通形式。Premiere / DaVinci Resolve / Avid 等が読み書きする。
//   構造は各社の解説・変換ツールの公開仕様で確認した:
//   - 先頭に `TITLE: <題>` と `FCM: NON-DROP FRAME` または `FCM: DROP FRAME`。
//   - イベント行は「番号(001〜999) リール名(最大 8 文字) トラック(C の位置) トランジション
//     素材イン 素材アウト 記録イン 記録アウト」。タイムコードは HH:MM:SS:FF。
//   - トラック表記は V(映像)/ A / A2 / A3 / A4(音声。標準で最大 4ch)。
//   - トランジションは C(カット)/ D(ディゾルブ)/ W(ワイプ)。ディゾルブ・ワイプは 2 行で表す。
//   - リール名が付けられない素材は AX を使う慣例。
//   - イベントの後ろに `* FROM CLIP NAME: …` / `* SOURCE FILE: …` のコメント行を付けるのは
//     Premiere 等の書き出しで広く使われる再リンク用の慣例。
// - ドロップフレーム(29.97 / 59.94)は、1 分ごと(10 分の倍数を除く)にフレーム番号を
//   2 個(59.94 は 4 個)読み飛ばす数え方。FCM 行と合わせてタイムコードが実時間に合う。
//
// ## 第 1 段の対応範囲(詳細は docs/FCPXMLとEDL.md)
// - 書き出しのみ(読み込みは対象外)。映像は代表の 1 トラック分、音声は最大 4 トラック分。
// - すべてのイベントはカット(C)として書く。MovieCut のトランジションはクリップの入/出に
//   付く形で、CMX の「クリップ間のトランジション」とは意味が違うため、無理に D へは変換せず
//   レポートに明示する。エフェクト・キーフレーム等は EDL に表す場所がないため対象外(レポートに明示)。

/// MovieCut の `Project` を CMX 3600 形式の EDL へ書き出すエクスポーター。
public enum EdlExporter {

    // MARK: レポート

    /// イベントとして書けなかったクリップ。
    public struct Skipped: Equatable {
        public var label: String
        public var reason: String
        public init(label: String, reason: String) { self.label = label; self.reason = reason }
    }

    /// 書き出しレポート。何が書けて、何が落ちたかを呼び出し側が利用者に見せるためのもの。
    public struct Report: Equatable {
        /// 書けたイベント数。
        public var eventCount: Int = 0
        /// 書けなかったクリップ。
        public var skipped: [Skipped] = []
        /// 注記(近似・仕様上の注意など)。
        public var notes: [String] = []
        public init() {}
        public var hasLoss: Bool { !skipped.isEmpty }
        public var summaryLines: [String] {
            var lines = [String(format: L10n.t("書き出し: %d イベント"), eventCount)]
            for s in skipped { lines.append(String(format: L10n.t("書き出せませんでした %@: %@"), s.label, L10n.t(s.reason))) }
            for n in notes { lines.append(String(format: L10n.t("注記: %@"), L10n.t(n))) }
            return lines
        }
    }

    /// 書き出し結果(EDL テキストとレポート)。
    public struct Output {
        public var text: String
        public var report: Report
        public init(text: String, report: Report) { self.text = text; self.report = report }
    }

    // MARK: タイムコード

    /// フレーム番号 → タイムコード文字列(HH:MM:SS:FF)。
    /// nominal は公称フレームレート(30 / 60 / 24 など)、drop はドロップフレーム数えかどうか。
    public static func timecode(frame: Int, nominal: Int, drop: Bool) -> String {
        let f = max(0, frame)
        let nom = max(1, nominal)
        if !drop {
            let ff = f % nom
            let totalSeconds = f / nom
            return String(format: "%02d:%02d:%02d:%02d", totalSeconds / 3600, (totalSeconds / 60) % 60, totalSeconds % 60, ff)
        }
        // ドロップフレーム: 10 分ブロック = 公称 10 分から「9 分 × 読み飛ばし数」を引いたフレーム数。
        // ブロックの先頭の分(10 分の倍数の分)だけ読み飛ばしがなく、それ以外は先頭の番号を飛ばす。
        let dropCount = nom == 60 ? 4 : 2
        let framesPerMinute = nom * 60 - dropCount
        let framesPer10Minutes = nom * 600 - dropCount * 9
        let tens = f / framesPer10Minutes
        var rest = f % framesPer10Minutes
        let minuteInBlock: Int
        let labelInMinute: Int
        if rest < nom * 60 {
            minuteInBlock = 0
            labelInMinute = rest
        } else {
            rest -= nom * 60
            minuteInBlock = 1 + rest / framesPerMinute
            labelInMinute = (rest % framesPerMinute) + dropCount
        }
        let totalMinutes = tens * 10 + minuteInBlock
        let ss = labelInMinute / nom
        let ff = labelInMinute % nom
        return String(format: "%02d:%02d:%02d:%02d", totalMinutes / 60, totalMinutes % 60, ss, ff)
    }

    /// プロジェクトの fps から (公称レート, ドロップフレームか) を決める。
    public static func rateInfo(fps: Double) -> (nominal: Int, drop: Bool) {
        let rate = XmemlRate.from(fps: fps)
        return (rate.timebase, XmemlRate.isDropFrame(timebase: rate.timebase, ntsc: rate.ntsc))
    }

    // MARK: リール名

    /// CMX のリール名(英大文字数字のみ・最大 8 文字)。素材ごとに一意になるよう、
    /// 衝突したら末尾に連番を付ける。付けられない素材は "AX"。
    public static func reelName(for src: String?, used: inout [String: String]) -> String {
        let key = src ?? ""
        if let existing = used[key] { return existing }
        var base = ""
        if let src, !src.isEmpty {
            base = (src as NSString).lastPathComponent
            base = (base as NSString).deletingPathExtension
        }
        // CMX のリール名は ASCII の英数字だけ(日本語などは含めない)。
        var cleaned = ""
        for scalar in base.uppercased().unicodeScalars {
            let v = scalar.value
            if (v >= 48 && v <= 57) || (v >= 65 && v <= 90) { cleaned.unicodeScalars.append(scalar) }
        }
        if cleaned.isEmpty { cleaned = "AX" }
        var candidate = String(cleaned.prefix(8))
        if used.values.contains(candidate) {
            var n = 2
            while n < 100 {
                let suffix = String(n)
                let c = String(cleaned.prefix(8 - suffix.count)) + suffix
                if !used.values.contains(c) { candidate = c; break }
                n += 1
            }
        }
        used[key] = candidate
        return candidate
    }

    // MARK: 入口

    /// プロジェクトを EDL テキストにする。元のプロジェクトは変更しない。
    public static func export(project: Project, title: String = "MovieCut") -> Output {
        var report = Report()
        let fpsValue = project.frameRate.value
        let (nominal, drop) = rateInfo(fps: project.fps)
        if XmemlRate.from(fps: project.fps).isApproximate {
            report.notes.append("フレームレート \(FrameRate.label(project.fps))fps は整数のタイムコードで正確に表せないため、公称 \(nominal)fps として書きました")
        }
        func frames(_ seconds: Double) -> Int { XmemlText.frames(seconds, fpsValue: fpsValue) }
        func tc(_ frame: Int) -> String { timecode(frame: frame, nominal: nominal, drop: drop) }

        struct Event {
            var recIn: Int
            var recOut: Int
            var srcIn: Int
            var srcOut: Int
            var channel: String
            var channelOrder: Int
            var reel: String
            var comments: [String]
        }
        var events: [Event] = []
        var usedReels: [String: String] = [:]

        func clipLabel(_ clip: Clip) -> String {
            if let src = clip.src, !src.isEmpty { return XmemlText.displayName(for: src) }
            if let text = clip.text, !text.isEmpty { return String(text.prefix(20)) }
            return "\(clip.type.rawValue) クリップ"
        }

        func makeEvent(clip: Clip, channel: String, channelOrder: Int) -> Event? {
            let label = clipLabel(clip)
            if clip.hasTimeRemap {
                report.notes.append("クリップ「\(label)」は速度変更等があるため、素材側の長さで速度が伝わる形にしました(モーション行 M2 は書きません)")
            }
            if clip.transitionIn != nil || clip.transitionOut != nil {
                report.notes.append("クリップ「\(label)」のトランジションは CMX のカット(C)として書きました(MovieCut の入/出トランジションはクリップ間のトランジションとは意味が違うため)")
            }
            let recIn = frames(clip.start)
            let recOut = recIn + frames(clip.duration)
            let srcIn = frames(clip.offset)
            let srcOut = srcIn + frames(clip.duration * clip.effectiveSpeed)
            let reel = reelName(for: clip.src, used: &usedReels)
            var comments = ["* FROM CLIP NAME: \(label)"]
            if let src = clip.src, !src.isEmpty { comments.append("* SOURCE FILE: \(src)") }
            return Event(recIn: recIn, recOut: recOut, srcIn: srcIn, srcOut: srcOut,
                         channel: channel, channelOrder: channelOrder, reel: reel, comments: comments)
        }

        // 映像: 映像クリップを含む最初のトラックを代表(V)にする。CMX 3600 は映像 1 トラックが前提。
        let visualTypes: Set<ClipType> = [.video, .image]
        var videoTrackUsed: Track? = nil
        for track in project.tracks {
            let visual = track.clips.filter { visualTypes.contains($0.type) }
            guard !visual.isEmpty else { continue }
            if videoTrackUsed == nil {
                videoTrackUsed = track
                for clip in visual.sorted(by: { $0.start < $1.start }) {
                    if let e = makeEvent(clip: clip, channel: "V", channelOrder: 0) { events.append(e) }
                }
                for clip in track.clips where !visualTypes.contains(clip.type) && clip.type != .audio {
                    report.skipped.append(Skipped(label: clipLabel(clip), reason: "EDL で表せるクリップ(映像・音声)ではないため"))
                }
            } else {
                for clip in visual {
                    report.skipped.append(Skipped(label: clipLabel(clip), reason: "CMX 3600 の EDL は映像 1 トラック分のみのため、代表トラック以外の映像は書きません"))
                }
            }
        }
        if videoTrackUsed == nil {
            report.notes.append("映像クリップがありませんでした")
        }

        // 音声: 音声クリップを含むトラックを順に A / A2 / A3 / A4 へ(最大 4)。
        let audioChannels = ["A", "A2", "A3", "A4"]
        var audioIndex = 0
        for track in project.tracks {
            let audio = track.clips.filter { $0.type == .audio }
            guard !audio.isEmpty else { continue }
            if audioIndex >= audioChannels.count {
                for clip in audio {
                    report.skipped.append(Skipped(label: clipLabel(clip), reason: "CMX 3600 の音声は最大 4 トラックのため書きません"))
                }
                continue
            }
            let channel = audioChannels[audioIndex]
            for clip in audio.sorted(by: { $0.start < $1.start }) {
                if let e = makeEvent(clip: clip, channel: channel, channelOrder: 1 + audioIndex) { events.append(e) }
            }
            audioIndex += 1
        }

        // 記録イン順(同点は映像→音声の順)に並べ、番号を 001 から振り直す。
        events.sort { ($0.recIn, $0.channelOrder) < ($1.recIn, $1.channelOrder) }
        if events.count > 999 {
            report.notes.append("イベントが 999 件を超えたため、記録順の先頭 999 件だけを書きました(CMX 3600 の上限)")
            events = Array(events.prefix(999))
        }
        var outLines: [String] = []
        let safeTitle = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        outLines.append("TITLE: \(safeTitle)")
        outLines.append("FCM: \(drop ? "DROP FRAME" : "NON-DROP FRAME")")
        outLines.append("")
        for (i, e) in events.enumerated() {
            let line = String(format: "%03d  %@ %@ C        %@ %@ %@ %@", i + 1,
                              e.reel.padding(toLength: 8, withPad: " ", startingAt: 0),
                              e.channel.padding(toLength: 5, withPad: " ", startingAt: 0),
                              tc(e.srcIn), tc(e.srcOut), tc(e.recIn), tc(e.recOut))
            outLines.append(line)
            outLines.append(contentsOf: e.comments)
        }
        report.eventCount = events.count
        return Output(text: outLines.joined(separator: "\n") + "\n", report: report)
    }

    /// プロジェクトを `.edl` ファイルに書く。レポートを返す。
    @discardableResult
    public static func write(project: Project, to url: URL, title: String = "MovieCut") throws -> Report {
        let out = export(project: project, title: title)
        try out.text.write(to: url, atomically: true, encoding: .utf8)
        return out.report
    }
}
