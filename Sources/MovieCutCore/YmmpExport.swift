import Foundation

/// MovieCut の `Project` を YMM4(ゆっくりMovieMaker4)のプロジェクトファイル `.ymmp`(JSON 形式)へ書き戻すエクスポーター。
///
/// ## 方針(インポーター `YmmpImporter` の変換対応表の逆向き)
/// - 対応表にある要素は、インポーターが読める形に正確に戻す(往復テストで検証する)。
/// - 対応できない要素(MovieCut 独自機能・YMM4 に相当表現が無いもの)は、**黙って落とさず**
///   書き出しレポート(`Report.unsupported` / `Report.droppedFeatures` / `Report.notes`)に理由つきで明示する。
/// - 実 YMM4 が無い環境では、形式の構造検証(このエクスポーターの出力を `YmmpImporter` が
///   変換できること=往復)と JSON 構造の確認までを保証範囲とする。実 YMM4 での読み込みは未検証。
public enum YmmpExporter {

    // MARK: - レポート

    /// 書き出せなかったクリップ 1 件分(アイテムごと落ちたもの)。
    public struct Unsupported: Equatable {
        /// MovieCut 側のクリップ種類(`ClipType.rawValue`)。
        public var typeName: String
        /// 人が識別するための短いラベル。
        public var label: String
        /// 書き出せなかった理由。
        public var reason: String
        public init(typeName: String, label: String, reason: String) {
            self.typeName = typeName; self.label = label; self.reason = reason
        }
    }

    /// クリップ自体は書き出せたが、一部の機能・値が落ちた 1 件分。
    public struct DroppedFeature: Equatable {
        public var label: String
        /// 落ちた機能の名前(例: `キーフレーム`)。
        public var feature: String
        public var reason: String
        public init(label: String, feature: String, reason: String) {
            self.label = label; self.feature = feature; self.reason = reason
        }
    }

    /// 書き出しレポート。何が書けて、何が落ちたかを呼び出し側(UI / CLI)が利用者に見せるためのもの。
    public struct Report: Equatable {
        /// 種類ごとの書き出し件数(キーは MovieCut の `ClipType.rawValue`)。
        public var convertedCounts: [String: Int] = [:]
        /// アイテムごと書き出せなかったもの。
        public var unsupported: [Unsupported] = []
        /// クリップの一部機能が落ちたもの。
        public var droppedFeatures: [DroppedFeature] = []
        /// 書き出し時の注記(近似・仕様上の注意など)。
        public var notes: [String] = []
        public init() {}
        /// 書き出せたアイテムの総数。
        public var convertedCount: Int { convertedCounts.values.reduce(0, +) }
        /// 落ちたものが 1 件でもあるか。
        public var hasLoss: Bool { !unsupported.isEmpty || !droppedFeatures.isEmpty }
        /// 人に見せる要約(複数行)。
        public var summaryLines: [String] {
            var lines = ["書き出し: \(convertedCount) 件"]
            for u in unsupported { lines.append("書き出せませんでした [\(u.typeName)] \(u.label): \(u.reason)") }
            for d in droppedFeatures { lines.append("一部のみ書き出し \(d.label): \(d.feature)(\(d.reason))") }
            for n in notes { lines.append("注記: \(n)") }
            return lines
        }
    }

    /// 書き出し結果。
    public struct Output {
        public var data: Data
        public var report: Report
        public init(data: Data, report: Report) { self.data = data; self.report = report }
    }

    // MARK: - 入口

    /// プロジェクトを `.ymmp`(JSON)データにする。元のプロジェクトは変更しない。
    public static func export(project: Project, timelineName: String = "メイン") -> Output {
        var report = Report()
        var builder = Builder(project: project, report: &report)
        let root = builder.buildRoot(timelineName: timelineName)
        report = builder.report
        // キーの順序を安定させる(テストでの比較と差分の見やすさのため)。YMM4 側の読み込みは順序に依存しない。
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Output(data: data, report: report)
    }

    /// プロジェクトを `.ymmp` ファイルに書く。レポートを返す(落ちた要素の確認用)。
    @discardableResult
    public static func write(project: Project, to url: URL, timelineName: String = "メイン") throws -> Report {
        let out = export(project: project, timelineName: timelineName)
        try out.data.write(to: url, options: [.atomic])
        return out.report
    }

    // MARK: - 値の整形(インポーターの逆変換)

    /// MovieCut の `#rrggbb` を YMM4 の `#AARRGGBB`(アルファ FF)に。不正な値は nil。
    static func argb(_ s: String?) -> String? {
        guard var hex = s?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 8 { hex.removeFirst(2) }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#FF" + hex.uppercased()
    }

    /// 秒を .NET の TimeSpan 文字列(`hh:mm:ss.fffffff`)にする(インポーターの `timeSpanSeconds` の逆)。
    static func timeSpanString(_ seconds: Double) -> String {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        let totalTicks = Int((clamped * 10_000_000).rounded())  // 1 tick = 100ns
        let ticks = totalTicks % 10_000_000
        var rest = totalTicks / 10_000_000
        let s = rest % 60; rest /= 60
        let m = rest % 60; rest /= 60
        let h = rest  // 日は使わず時間に繰り上げる(TimeSpan のパーサは "25:00:00" も読める)
        return String(format: "%02d:%02d:%02d.%07d", h, m, s, ticks)
    }

    /// YMM4 のアニメーション可能な値(現行形式: 先頭の値だけ持つ静止値)。
    static func anim(_ v: Double) -> [String: Any] {
        ["AnimationType": "なし", "Span": 0.0, "Values": [["Value": v]]]
    }

    /// フレーム換算(四捨五入)。
    static func frame(_ seconds: Double, fps: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int((seconds * fps).rounded())
    }

    // MARK: - 変換の本体

    private struct Builder {
        var project: Project
        var report: Report
        var charNameById: [String: String] = [:]
        private var notedRotation = false
        private var notedVolumeRoundTrip = false
        private var notedCharacterVoiceParams = false

        init(project: Project, report: inout Report) {
            self.project = project
            self.report = report
            for c in project.characters { charNameById[c.id] = c.name }
        }

        mutating func buildRoot(timelineName: String) -> [String: Any] {
            let fps = project.fps
            var items: [[String: Any]] = []
            var maxLayer = 0
            for (layer, track) in project.tracks.enumerated() {
                if track.muted == true || track.solo == true {
                    report.notes.append("トラック「\(track.name)」のミュート/ソロは YMM4 のアイテムに相当が無いため書き出していません")
                }
                for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                    if let item = convert(clip, layer: layer, trackHidden: track.isHidden) {
                        items.append(item)
                        maxLayer = max(maxLayer, layer)
                    }
                }
            }
            reportProjectLevelLosses()
            let endFrame = YmmpExporter.frame(project.endTime, fps: fps)
            let timeline: [String: Any] = [
                "CurrentFrame": 0,
                "ID": UUID().uuidString,
                "Items": items,
                "Length": endFrame,
                "MaxLayer": maxLayer,
                "Name": timelineName,
                "VideoInfo": [
                    "FPS": fps == fps.rounded() ? Int(fps) : fps,
                    "Height": project.height,
                    "Hz": 48000,
                    "Width": project.width,
                ] as [String: Any],
            ]
            return [
                "Characters": project.characters.map(convertCharacter),
                "SelectedTimelineIndex": 0,
                "Timelines": [timeline],
            ]
        }

        /// プロジェクト単位で YMM4 に行き先が無い要素の明示。
        private mutating func reportProjectLevelLosses() {
            if !project.markers.isEmpty {
                report.droppedFeatures.append(DroppedFeature(label: "プロジェクト", feature: "マーカー \(project.markers.count) 件", reason: "YMM4 の .ymmp にはマーカーの保存形式が無いため"))
            }
            if !project.tachies.isEmpty {
                report.droppedFeatures.append(DroppedFeature(label: "プロジェクト", feature: "立ち絵素材 \(project.tachies.count) 件", reason: "立ち絵は TachieItem として書き出していないため(未対応)"))
            }
            if !project.multicams.isEmpty {
                report.droppedFeatures.append(DroppedFeature(label: "プロジェクト", feature: "マルチカメラ", reason: "MovieCut 独自機能のため"))
            }
            if !project.readingDictionary.isEmpty {
                report.droppedFeatures.append(DroppedFeature(label: "プロジェクト", feature: "読み辞書 \(project.readingDictionary.count) 件", reason: "YMM4 のキャラクター辞書とは形式が違うため"))
            }
            if !project.scriptText.isEmpty {
                report.droppedFeatures.append(DroppedFeature(label: "プロジェクト", feature: "台本テキスト", reason: "MovieCut 独自の保存項目のため"))
            }
            if project.hasTransparentBackground {
                report.notes.append("背景の透明は .ymmp には書き出していません(YMM4 側の背景設定に従います)")
            }
            if project.codec.lowercased() != "h264" {
                report.notes.append("書き出しコーデック(\(project.codec))は動画ファイルの形式であり、.ymmp(プロジェクト)には含まれません")
            }
        }

        /// YMM4 のキャラクター定義。インポーターが読むキー(Name / Color / FontColor / Voice.API / VoiceParameter)を戻す。
        private func convertCharacter(_ c: Character) -> [String: Any] {
            var dict: [String: Any] = ["Name": c.name]
            if let color = YmmpExporter.argb(c.color) { dict["Color"] = color }
            if let sub = YmmpExporter.argb(c.subtitleColor) { dict["FontColor"] = sub }
            dict["IsJimakuVisible"] = true
            switch c.engine.lowercased() {
            case "aquestalk":
                dict["Voice"] = ["API": "aquestalk", "Arg": ""]
                dict["VoiceParameter"] = ["$type": "YukkuriMovieMaker.Voice.AquesTalkVoiceParameter, YukkuriMovieMaker"]
            default:
                dict["Voice"] = ["API": "voicevox", "Arg": ""]
                var param: [String: Any] = ["$type": "YukkuriMovieMaker.Voice.VOICEVOXVoiceParameter, YukkuriMovieMaker"]
                param["StyleID"] = c.speaker ?? 0
                dict["VoiceParameter"] = param
            }
            return dict
        }

        /// キャラクターの声パラメータのうち .ymmp に戻せないものの注記(1 回だけ)。
        private mutating func noteCharacterVoiceParamsIfNeeded() {
            guard !notedCharacterVoiceParams else { return }
            let has = project.characters.contains { $0.speed != nil || $0.pitch != nil || $0.intonation != nil || $0.voice != nil }
            if has {
                report.notes.append("キャラクターの速度・音程・抑揚・AquesTalk の声種は、換算基準が確定できないため .ymmp には書き出していません")
                notedCharacterVoiceParams = true
            }
        }

        private func label(of clip: Clip) -> String {
            if let t = clip.text, !t.isEmpty { return String(t.prefix(24)) }
            if let s = clip.src, !s.isEmpty { return (s.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }
            return clip.type.rawValue
        }

        /// クリップ 1 件を YMM4 アイテムにする。対応できないものはレポートに積んで nil。
        mutating func convert(_ clip: Clip, layer: Int, trackHidden: Bool) -> [String: Any]? {
            let label = label(of: clip)
            let fps = project.fps
            let supported: Set<ClipType> = [.voice, .text, .image, .video, .audio]
            guard supported.contains(clip.type) else {
                let reason: String
                switch clip.type {
                case .tachie: reason = "立ち絵クリップは TachieItem への変換が未対応のため"
                case .compound: reason = "複合クリップは MovieCut 独自機能で YMM4 に相当が無いため"
                case .shape: reason = "図形クリップは YMM4 の ShapeItem と形式が違うため"
                case .blur: reason = "ぼかしクリップは YMM4 のエフェクトとして表現できないため"
                case .adjustment: reason = "調整レイヤーは MovieCut 独自機能のため"
                case .visualizer: reason = "音声ビジュアライザは MovieCut 独自機能のため"
                default: reason = "未対応のクリップ種類のため"
                }
                report.unsupported.append(Unsupported(typeName: clip.type.rawValue, label: label, reason: reason))
                return nil
            }
            guard clip.duration > 0 else {
                report.unsupported.append(Unsupported(typeName: clip.type.rawValue, label: label, reason: "長さが 0 以下のため"))
                return nil
            }

            var item: [String: Any] = [:]
            let typeName: String
            switch clip.type {
            case .voice: typeName = "VoiceItem"
            case .text: typeName = "TextItem"
            case .image: typeName = "ImageItem"
            case .video: typeName = "VideoItem"
            default: typeName = "AudioItem"
            }
            item["$type"] = "YukkuriMovieMaker.Project.Items.\(typeName), YukkuriMovieMaker"
            item["Frame"] = max(0, YmmpExporter.frame(clip.start, fps: fps))
            item["Length"] = max(1, YmmpExporter.frame(clip.duration, fps: fps))
            item["Layer"] = layer
            item["Group"] = 0
            item["IsLocked"] = clip.locked == true
            item["IsHidden"] = trackHidden

            switch clip.type {
            case .voice:
                guard convertVoice(clip, into: &item, label: label) else { return nil }
            case .text:
                guard let text = clip.text, !text.isEmpty else {
                    report.unsupported.append(Unsupported(typeName: clip.type.rawValue, label: label, reason: "本文(text)が空のため"))
                    return nil
                }
                item["Text"] = text
                applyTextStyle(clip, into: &item)
                applyPosition(clip, into: &item)
            default:  // image / video / audio
                guard let src = clip.src, !src.isEmpty else {
                    report.unsupported.append(Unsupported(typeName: clip.type.rawValue, label: label, reason: "素材パス(src)が無いため"))
                    return nil
                }
                item["FilePath"] = Self.ymmpPath(src)
                if clip.offset != 0 { item["ContentOffset"] = YmmpExporter.timeSpanString(clip.offset) }
                if let speed = clip.speed, abs(speed - 1) > 0.000_001 { item["PlaybackRate"] = speed * 100 }
                if clip.type != .audio {
                    if let scale = clip.scale { item["Zoom"] = YmmpExporter.anim(scale * 100) }
                    applyPosition(clip, into: &item)
                }
                if let opacity = clip.opacity { item["Opacity"] = YmmpExporter.anim(opacity * 100) }
            }

            // 共通: フェード・音量(YMM4 側の値として書く。MovieCut への再読み込みでは音量は引き継がれない)
            if let f = clip.fadeIn, f > 0 { item["FadeIn"] = f }
            if let f = clip.fadeOut, f > 0 { item["FadeOut"] = f }
            if let v = clip.volume {
                item["Volume"] = YmmpExporter.anim(v * 100)
                if !notedVolumeRoundTrip {
                    report.notes.append("音量は YMM4 の Volume として書き出しました(MovieCut への再読み込みでは引き継がれません)")
                    notedVolumeRoundTrip = true
                }
            }
            if let r = clip.rotation, r != 0 {
                item["Rotation"] = YmmpExporter.anim(r)
                if !notedRotation {
                    report.notes.append("回転は YMM4 の Rotation として書き出しました(MovieCut への再読み込みでは引き継がれません)")
                    notedRotation = true
                }
            }
            noteDroppedFeatures(of: clip, label: label)
            noteCharacterVoiceParamsIfNeeded()
            report.convertedCounts[clip.type.rawValue, default: 0] += 1
            return item
        }

        private mutating func convertVoice(_ clip: Clip, into item: inout [String: Any], label: String) -> Bool {
            guard let text = clip.text, !text.isEmpty else {
                report.unsupported.append(Unsupported(typeName: clip.type.rawValue, label: label, reason: "読み上げ文(text)が空のため"))
                return false
            }
            item["Serif"] = clip.subtitleText ?? text
            item["Hatsuon"] = text
            if let charId = clip.charId, let name = charNameById[charId] {
                item["CharacterName"] = name
            } else if clip.charId != nil {
                report.droppedFeatures.append(DroppedFeature(label: label, feature: "キャラクター割り当て", reason: "charId に対応するキャラクターがプロジェクトに無いため"))
            }
            switch clip.subtitle {
            case .some(false): item["JimakuVisibility"] = "Hidden"
            case .some(true): item["JimakuVisibility"] = "Visible"
            case .none: item["JimakuVisibility"] = "UseCharacterSetting"
            }
            applyTextStyle(clip, into: &item)
            return true
        }

        /// 文字スタイル(インポーターが読む Font / FontSize / FontColor / Style・StyleColor)。
        private func applyTextStyle(_ clip: Clip, into item: inout [String: Any]) {
            if let font = clip.font, !font.isEmpty { item["Font"] = font }
            if let size = clip.fontSize { item["FontSize"] = YmmpExporter.anim(size) }
            if let color = YmmpExporter.argb(clip.color) { item["FontColor"] = color }
            if let outline = YmmpExporter.argb(clip.outline) {
                item["Style"] = "SharpBorder"
                item["StyleColor"] = outline
            }
        }

        /// 位置の逆換算: MovieCut の 0〜1(中心)を YMM4 のピクセル(中心基準・Y は上向き正)に戻す。
        private func applyPosition(_ clip: Clip, into item: inout [String: Any]) {
            if let x = clip.x { item["X"] = YmmpExporter.anim((x - 0.5) * Double(project.width)) }
            if let y = clip.y { item["Y"] = YmmpExporter.anim((0.5 - y) * Double(project.height)) }
        }

        /// クリップの一部機能の落下を明示する(黙って落とさない)。
        private mutating func noteDroppedFeatures(of clip: Clip, label: String) {
            func drop(_ feature: String, _ reason: String) {
                report.droppedFeatures.append(DroppedFeature(label: label, feature: feature, reason: reason))
            }
            if !clip.keyframes.isEmpty { drop("キーフレーム", "YMM4 のアニメーション形式への変換が未対応のため") }
            if !clip.effects.isEmpty { drop("映像エフェクト \(clip.effects.count) 件", "YMM4 のエフェクト形式への変換が未対応のため") }
            if let fx = clip.audioFx, !fx.isEmpty { drop("音声エフェクト", "YMM4 の音声エフェクト形式への変換が未対応のため") }
            if clip.transitionIn != nil || clip.transitionOut != nil { drop("トランジション", "YMM4 への変換が未対応のため") }
            if clip.textStyle != nil { drop("文字の装飾(影・箱・グラデーション等)", "YMM4 への変換が未対応のため") }
            if clip.textAnim != nil { drop("文字アニメーション", "YMM4 への変換が未対応のため") }
            if !clip.ruby.isEmpty { drop("ルビ \(clip.ruby.count) 件", "YMM4 への変換が未対応のため") }
            if clip.bubble != nil { drop("吹き出し", "MovieCut 独自機能のため") }
            if clip.counter != nil || clip.valueRef != nil { drop("カウンター/値の表示", "MovieCut 独自機能のため") }
            if clip.reverse == true { drop("逆再生", "YMM4 のアイテムには逆再生の指定が無いため") }
            if clip.speedRamp != nil { drop("速度ランプ", "YMM4 への変換が未対応のため(一定速度として書き出し)") }
            if clip.freeze == true { drop("フリーズフレーム", "YMM4 への変換が未対応のため") }
            if clip.crop != nil { drop("切り抜き(クロップ)", "YMM4 への変換が未対応のため") }
            if clip.flipH == true || clip.flipV == true { drop("反転", "YMM4 への変換が未対応のため") }
            if clip.mask != nil { drop("マスク", "YMM4 への変換が未対応のため") }
            if clip.objectMask != nil { drop("オブジェクトマスク", "YMM4 への変換が未対応のため") }
            if clip.hslMask != nil { drop("HSLマスク", "YMM4 への変換が未対応のため") }
            if clip.blendMode != nil { drop("ブレンドモード", "YMM4 への変換が未対応のため") }
            if clip.muted == true { drop("クリップ消音", "YMM4 のアイテムに相当が無いため") }
            if clip.blur != nil, (clip.blur ?? 0) > 0 { drop("ぼかし", "YMM4 のエフェクトとして表現できないため") }
            if clip.pan != nil { drop("左右の振り分け(パン)", "YMM4 への変換が未対応のため") }
            if clip.duck != nil { drop("自動ダッキング", "MovieCut 独自機能のため") }
            if clip.stabilize != nil { drop("手ぶれ補正", "MovieCut 独自機能のため") }
        }

        /// YMM4(Windows)向けのパス表記。ドライブ文字を含むパスは区切りを `\` に戻し、それ以外(相対・POSIX)はそのまま。
        static func ymmpPath(_ src: String) -> String {
            let isWindowsDrive = src.count >= 2 && src[src.index(src.startIndex, offsetBy: 1)] == ":"
            return isWindowsDrive ? src.replacingOccurrences(of: "/", with: "\\") : src
        }
    }
}
