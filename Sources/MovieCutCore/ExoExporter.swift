import Foundation

// MARK: - exo 書き出し(W3-26 / YMM4 監査 #71)
//
// AviUtl の拡張編集プラグイン(ExEdit)用プロジェクトファイル `.exo` への書き出し。
// `.exo` は INI 風テキスト(Shift_JIS)。構造は次のとおり:
//   [exedit]            画面サイズ・fps・総フレーム数・音声レート
//   [0] [1] ...         オブジェクト(クリップ)ごとの配置(start/end は 1 始まりのフレーム番号、layer は 1 始まり)
//   [0.0] [0.1] ...     そのオブジェクトのエフェクト(素材指定 + 標準描画/標準再生)
// テキスト本文は AviUtl の流儀で UTF-16LE の 16 進文字列にする(文字コード問題を避けるため)。
//
// ## 対応範囲(正直な明記)
// - 対応: 画像 / 動画 / 音声 / ボイス(素材ファイルがあるもの)の配置・基本パラメータと、テキストの配置・本文・サイズ・色。
// - 非対応: 上記以外のクリップ種類(立ち絵・図形・複合・ぼかし・調整・ビジュアライザ等)は
//   スキップし、理由をレポート(`ExoReport.unsupported`)に必ず残す(黙って落とさない。ymmp 書き戻しと同じ流儀)。
//   クリップの一部機能(キーフレーム・エフェクト・トランジション等)も exo に正確な行き先が無いものは
//   レポート(`droppedFeatures`)に残す。
// - 実 AviUtl での読み込み検証は未実施(検証環境が無いため)。保証範囲は、形式の構造と
//   自前パーサ(`ExoParser`)での往復まで。座標は中心基準ピクセルへの換算で、AviUtl 側の
//   Y 方向の符号は未検証の近似であることも docs に明記する。

public enum ExoExporter {

    // MARK: - レポート(ymmp 書き戻しのレポートと同じ流儀)

    public struct Unsupported: Equatable, Sendable {
        public var typeName: String
        public var label: String
        public var reason: String
        public init(typeName: String, label: String, reason: String) {
            self.typeName = typeName; self.label = label; self.reason = reason
        }
    }

    public struct DroppedFeature: Equatable, Sendable {
        public var label: String
        public var feature: String
        public var reason: String
        public init(label: String, feature: String, reason: String) {
            self.label = label; self.feature = feature; self.reason = reason
        }
    }

    public struct Report: Equatable, Sendable {
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

    public struct Output: Sendable {
        /// Shift_JIS のバイト列(AviUtl の流儀)。
        public var data: Data
        /// UTF-8 で読める同じ内容(テスト・確認用)。
        public var text: String
        public var report: Report
        public init(data: Data, text: String, report: Report) { self.data = data; self.text = text; self.report = report }
    }

    // MARK: - 入口

    public static func export(project: Project) -> Output {
        var report = Report()
        var builder = Builder(project: project, report: &report)
        let text = builder.build()
        report = builder.report
        let data: Data
        if let sjis = text.data(using: .shiftJIS) {
            data = sjis
        } else {
            // 変換できない文字が1つでもあると全体が UTF-8 になり AviUtl で読めなくなる。
            // その文字だけ代替文字にして、ファイル全体は Shift_JIS を保つ。
            data = (text as NSString).data(using: String.Encoding.shiftJIS.rawValue, allowLossyConversion: true) ?? Data()
            report.notes.append("Shift_JIS に変換できない文字があったため、代替文字に置き換えました")
        }
        return Output(data: data, text: text, report: report)
    }

    @discardableResult
    public static func write(project: Project, to url: URL) throws -> Report {
        let out = export(project: project)
        try out.data.write(to: url, options: [.atomic])
        return out.report
    }

    // MARK: - 値の整形

    /// exo のフレーム番号(1 始まり)。開始フレーム = round(start × fps) + 1。
    static func startFrame(_ seconds: Double, fps: Double) -> Int {
        guard seconds.isFinite else { return 1 }
        return max(1, Int((seconds * fps).rounded()) + 1)
    }

    /// 終了フレーム(そのフレームを含む)。開始より前にはならない。
    static func endFrame(start: Double, duration: Double, fps: Double) -> Int {
        let s = startFrame(start, fps: fps)
        guard duration.isFinite else { return s }
        return max(s, Int(((start + duration) * fps).rounded()))
    }

    /// 数値の表記(整数は小数なし、それ以外は小数 2 桁まで・末尾の 0 なし)。
    static func num(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// テキスト本文 → UTF-16LE バイト列の 16 進文字列(AviUtl の「テキスト」項目の流儀)。
    static func hexText(_ s: String) -> String {
        var out = ""
        for unit in s.utf16 {
            out += String(format: "%02x", unit & 0xff)
            out += String(format: "%02x", unit >> 8)
        }
        return out
    }

    /// `hexText` の逆変換。読めない並びは nil。
    static func decodeHexText(_ hex: String) -> String? {
        let chars = Array(hex)
        guard chars.count % 4 == 0 else { return nil }
        var units: [UInt16] = []
        var i = 0
        while i < chars.count {
            guard let lo = UInt8(String(chars[i..<(i + 2)]), radix: 16),
                  let hi = UInt8(String(chars[(i + 2)..<(i + 4)]), radix: 16) else { return nil }
            units.append(UInt16(lo) | UInt16(hi) << 8)
            i += 4
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// MovieCut の `#rrggbb` → exo の色(0xRRGGBB の 16 進 6 桁)。不正な値は nil。
    static func exoColor(_ s: String?) -> String? {
        guard var hex = s?.trimmingCharacters(in: .whitespaces), hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex.lowercased()
    }

    /// Windows 向けパス表記(ymmp 書き戻しと同じ: ドライブ文字を含むパスは区切りを `\` に戻す)。
    static func exoPath(_ src: String) -> String {
        let isWindowsDrive = src.count >= 2 && src[src.index(src.startIndex, offsetBy: 1)] == ":"
        return isWindowsDrive ? src.replacingOccurrences(of: "/", with: "\\") : src
    }

    // MARK: - 変換の本体

    private struct Builder {
        var project: Project
        var report: Report

        init(project: Project, report: inout Report) {
            self.project = project
            self.report = report
        }

        mutating func build() -> String {
            let fps = project.frameRate.value
            var lines: [String] = []
            let totalFrames = project.frameRate.frameCount(duration: project.endTime)
            lines.append("[exedit]")
            lines.append("width=\(project.width)")
            lines.append("height=\(project.height)")
            lines.append("rate=\(project.frameRate.num)")
            lines.append("scale=\(project.frameRate.den)")
            lines.append("length=\(totalFrames)")
            lines.append("audio_rate=48000")
            lines.append("audio_ch=2")

            var index = 0
            for (layer, track) in project.tracks.enumerated() {
                for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                    guard let objectLines = convert(clip, index: index, layer: layer + 1, trackHidden: track.isHidden, fps: fps) else { continue }
                    lines.append(contentsOf: objectLines)
                    index += 1
                }
            }
            reportProjectLevelLosses()
            report.notes.append("実 AviUtl での読み込みは未検証です(構造と自前パーサでの往復までを確認)")
            return lines.joined(separator: "\r\n") + "\r\n"
        }

        private mutating func reportProjectLevelLosses() {
            if !project.markers.isEmpty {
                report.droppedFeatures.append(ExoExporter.DroppedFeature(label: "プロジェクト", feature: "マーカー \(project.markers.count) 件", reason: "exo にはマーカーの保存形式が無いため"))
            }
            if !project.tachies.isEmpty {
                report.droppedFeatures.append(ExoExporter.DroppedFeature(label: "プロジェクト", feature: "立ち絵素材 \(project.tachies.count) 件", reason: "立ち絵は exo のオブジェクトとして書き出していないため(未対応)"))
            }
            if !project.characters.isEmpty {
                report.notes.append("キャラクター(声の設定)は exo には含まれません(配置と素材ファイルだけを書き出します)")
            }
            if project.hasTransparentBackground {
                report.notes.append("背景の透明は exo には書き出していません(AviUtl 側の背景設定に従います)")
            }
        }

        private func label(of clip: Clip) -> String {
            if let t = clip.text, !t.isEmpty { return String(t.prefix(24)) }
            if let s = clip.src, !s.isEmpty { return (s.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent }
            return clip.type.rawValue
        }

        /// クリップ 1 件を exo のオブジェクト([i] + [i.0]…)にする。対応できないものはレポートに積んで nil。
        mutating func convert(_ clip: Clip, index: Int, layer: Int, trackHidden: Bool, fps: Double) -> [String]? {
            let label = label(of: clip)
            let supported: Set<ClipType> = [.image, .video, .audio, .voice, .text]
            guard supported.contains(clip.type) else {
                let reason: String
                switch clip.type {
                case .tachie: reason = "立ち絵クリップは exo への変換が未対応のため"
                case .compound: reason = "複合クリップは MovieCut 独自機能で exo に相当が無いため"
                case .shape: reason = "図形クリップは exo の図形オブジェクトと形式が違うため"
                case .blur: reason = "ぼかしクリップは exo のエフェクトとして表現できないため"
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
            if clip.isDisabled {
                report.unsupported.append(Unsupported(typeName: clip.type.rawValue, label: label, reason: "無効化されているクリップのため"))
                return nil
            }
            if trackHidden, clip.type != .audio, clip.type != .voice {
                report.notes.append("非表示レイヤーのクリップ「\(label)」も exo に書き出しました(AviUtl 側で表示を切り替えてください)")
            }

            var lines: [String] = []
            lines.append("[\(index)]")
            lines.append("start=\(ExoExporter.startFrame(clip.start, fps: fps))")
            lines.append("end=\(ExoExporter.endFrame(start: clip.start, duration: clip.duration, fps: fps))")
            lines.append("layer=\(layer)")
            lines.append("overlay=1")
            lines.append("camera=0")

            switch clip.type {
            case .image, .video:
                guard let src = clip.src, !src.isEmpty else {
                    report.unsupported.append(Unsupported(typeName: clip.type.rawValue, label: label, reason: "素材パス(src)が無いため"))
                    return nil
                }
                lines.append("[\(index).0]")
                if clip.type == .image {
                    lines.append("_name=画像ファイル")
                    lines.append("file=\(ExoExporter.exoPath(src))")
                } else {
                    lines.append("_name=動画ファイル")
                    lines.append("file=\(ExoExporter.exoPath(src))")
                    lines.append("再生位置=\(max(0, Int((clip.offset * fps).rounded())))")
                    if let speed = clip.speed, abs(speed - 1) > 0.000_001 { lines.append("再生速度=\(ExoExporter.num(speed * 100))") }
                    lines.append("ループ再生=0")
                }
                lines.append(contentsOf: drawSection(clip, index: index, sub: 1))
            case .audio, .voice:
                guard let src = clip.src, !src.isEmpty else {
                    let reason = clip.type == .voice ? "合成音声の素材ファイル(src)が無いため(先に声を書き出してください)" : "素材パス(src)が無いため"
                    report.unsupported.append(Unsupported(typeName: clip.type.rawValue, label: label, reason: reason))
                    return nil
                }
                lines.append("[\(index).0]")
                lines.append("_name=音声ファイル")
                lines.append("file=\(ExoExporter.exoPath(src))")
                if clip.offset != 0 { lines.append("再生位置=\(ExoExporter.num(clip.offset))") }
                if let speed = clip.speed, abs(speed - 1) > 0.000_001 { lines.append("再生速度=\(ExoExporter.num(speed * 100))") }
                lines.append("ループ再生=0")
                lines.append("[\(index).1]")
                lines.append("_name=標準再生")
                lines.append("音量=\(ExoExporter.num(clip.volumeOrDefault * 100))")
                lines.append("左右=\(ExoExporter.num((clip.pan ?? 0) * 100))")
            case .text:
                guard let text = clip.text, !text.isEmpty else {
                    report.unsupported.append(Unsupported(typeName: clip.type.rawValue, label: label, reason: "本文(text)が空のため"))
                    return nil
                }
                lines.append("[\(index).0]")
                lines.append("_name=テキスト")
                lines.append("サイズ=\(ExoExporter.num(clip.fontSizeOrDefault))")
                lines.append("表示速度=0")
                lines.append("自動スクロール=0")
                lines.append("B=\(clip.textStyle?.bold == true ? 1 : 0)")
                lines.append("I=\(clip.textStyle?.italic == true ? 1 : 0)")
                lines.append("type=0")
                lines.append("align=0")
                if let color = ExoExporter.exoColor(clip.color) { lines.append("color=\(color)") }
                if let font = clip.font, !font.isEmpty { lines.append("font=\(font)") }
                lines.append("テキスト=\(ExoExporter.hexText(text))")
                lines.append(contentsOf: drawSection(clip, index: index, sub: 1))
            default:
                return nil
            }

            noteDroppedFeatures(of: clip, label: label)
            report.convertedCounts[clip.type.rawValue, default: 0] += 1
            return lines
        }

        /// 標準描画(位置は中心基準ピクセルへ換算。MovieCut の x/y は中心 0〜1、Y は下向き正 → exo は Y 上向き正として反転)。
        private func drawSection(_ clip: Clip, index: Int, sub: Int) -> [String] {
            let x = (clip.xOrDefault - 0.5) * Double(project.width)
            let y = (0.5 - clip.yOrDefault) * Double(project.height)
            return ["[\(index).\(sub)]", "_name=標準描画",
                    "X=\(ExoExporter.num(x))", "Y=\(ExoExporter.num(y))", "Z=0",
                    "拡大率=\(ExoExporter.num(clip.scaleOrDefault * 100))",
                    "透明度=\(ExoExporter.num((1 - clip.opacityOrDefault) * 100))",
                    "回転=\(ExoExporter.num(clip.rotationOrDefault))",
                    "blend=0"]
        }

        private mutating func noteDroppedFeatures(of clip: Clip, label: String) {
            func drop(_ feature: String, _ reason: String) {
                report.droppedFeatures.append(DroppedFeature(label: label, feature: feature, reason: reason))
            }
            if !clip.keyframes.isEmpty { drop("キーフレーム", "exo のアニメーション形式への変換が未対応のため(開始時点の値で書き出し)") }
            if !clip.effects.isEmpty { drop("映像エフェクト \(clip.effects.count) 件", "exo のエフェクト形式への変換が未対応のため") }
            if let fx = clip.audioFx, !fx.isEmpty { drop("音声エフェクト", "exo の音声エフェクト形式への変換が未対応のため") }
            if clip.transitionIn != nil || clip.transitionOut != nil { drop("トランジション", "exo への変換が未対応のため") }
            if clip.textStyle != nil { drop("文字の装飾(影・箱・グラデーション等)", "太字・斜体以外は exo への変換が未対応のため") }
            if clip.textAnim != nil { drop("文字アニメーション", "exo への変換が未対応のため") }
            if !clip.ruby.isEmpty { drop("ルビ \(clip.ruby.count) 件", "exo への変換が未対応のため") }
            if clip.reverse == true { drop("逆再生", "exo のオブジェクトには逆再生の指定が無いため") }
            if clip.speedRamp != nil { drop("速度ランプ", "exo への変換が未対応のため(一定速度として書き出し)") }
            if clip.crop != nil { drop("切り抜き(クロップ)", "exo への変換が未対応のため") }
            if clip.flipH == true || clip.flipV == true { drop("反転", "exo への変換が未対応のため") }
            if clip.mask != nil { drop("マスク", "exo への変換が未対応のため") }
            if clip.objectMask != nil { drop("オブジェクトマスク", "exo への変換が未対応のため") }
            if clip.hslMask != nil { drop("HSLマスク", "exo への変換が未対応のため") }
            if clip.blendMode != nil { drop("ブレンドモード", "exo への変換が未対応のため(通常合成として書き出し)") }
            if clip.muted == true { drop("クリップ消音", "exo のオブジェクトに相当が無いため") }
            if clip.fadeIn != nil || clip.fadeOut != nil { drop("音声フェード", "exo への変換が未対応のため") }
        }
    }
}

// MARK: - exo の読み戻し(構造確認・往復テスト用)

/// `.exo` テキストをセクション→キー/値の辞書として読む最小パーサ。
/// AviUtl 本体の読み込み互換を保証するものではなく、書き出し構造の検証用。
public enum ExoParser {
    public struct Object: Equatable, Sendable {
        public var index: Int
        public var start: Int
        public var end: Int
        public var layer: Int
        /// エフェクト名(`[i.j]` の `_name`)の列(添字順)。
        public var effectNames: [String]
        /// セクション名("0", "0.0" …) → キー/値。
        public var sections: [String: [String: String]]
    }

    public struct Document: Equatable, Sendable {
        public var header: [String: String]
        public var objects: [Object]
    }

    public static func parse(_ text: String) -> Document? {
        var sections: [String: [String: String]] = [:]
        var order: [String] = []
        var current: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                if sections[current!] == nil { sections[current!] = [:]; order.append(current!) }
                continue
            }
            guard let cur = current, let eq = line.firstIndex(of: "=") else { continue }
            sections[cur]?[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let header = sections["exedit"] else { return nil }
        var objects: [Object] = []
        for name in order where Int(name) != nil {
            guard let sec = sections[name], let idx = Int(name) else { continue }
            var effects: [(Int, String)] = []
            for (secName, values) in sections {
                let parts = secName.split(separator: ".")
                if parts.count == 2, Int(parts[0]) == idx, let sub = Int(parts[1]), let n = values["_name"] {
                    effects.append((sub, n))
                }
            }
            objects.append(Object(index: idx,
                                  start: Int(sec["start"] ?? "") ?? 0,
                                  end: Int(sec["end"] ?? "") ?? 0,
                                  layer: Int(sec["layer"] ?? "") ?? 0,
                                  effectNames: effects.sorted { $0.0 < $1.0 }.map { $0.1 },
                                  sections: sections.filter { $0.key == name || $0.key.hasPrefix(name + ".") }))
        }
        return Document(header: header, objects: objects.sorted { $0.index < $1.index })
    }

    /// バイト列(Shift_JIS 優先、だめなら UTF-8)から読む。
    public static func parse(data: Data) -> Document? {
        let text = String(data: data, encoding: .shiftJIS) ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }
}
