import Foundation

// MARK: - OTIO(OpenTimelineIO, JSON 形式)書き出し・読み込み
//
// OpenTimelineIO 本体は使わず、`.otio` を JSON として自前で読み書きする(依存を増やさない)。
// 使うスキーマ: Timeline.1 / Stack.1 / Track.1 / Clip.1 / Gap.1 / ExternalReference.1 /
// TimeRange.1 / RationalTime.1 / LinearTimeWarp.1 / Marker.2。
// MovieCut 独自の情報は各オブジェクトの metadata["moviecut"] に置く(他ソフトは無視して素通しする)。
// 対応範囲の詳細は docs/OTIO書き出しと読み込み.md。

/// OTIO の RationalTime / TimeRange の JSON 化と読み取りの共通部品。
enum OtioJSON {
    static func rationalTime(frames: Int, rate: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "RationalTime.1", "rate": rate, "value": Double(frames)]
    }

    static func timeRange(startFrames: Int, durationFrames: Int, rate: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "TimeRange.1",
         "start_time": rationalTime(frames: startFrames, rate: rate),
         "duration": rationalTime(frames: durationFrames, rate: rate)]
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        return nil
    }

    /// RationalTime → (秒, rate)。
    static func seconds(_ any: Any?) -> (seconds: Double, rate: Double)? {
        guard let d = any as? [String: Any], let v = number(d["value"]), let r = number(d["rate"]), r > 0, v.isFinite else { return nil }
        return (v / r, r)
    }

    /// TimeRange → (開始秒, 長さ秒, rate)。
    static func range(_ any: Any?) -> (start: Double, duration: Double, rate: Double)? {
        guard let d = any as? [String: Any],
              let s = seconds(d["start_time"]), let du = seconds(d["duration"]) else { return nil }
        return (s.seconds, du.seconds, s.rate)
    }

    static func schemaName(_ d: [String: Any]) -> String {
        let s = (d["OTIO_SCHEMA"] as? String) ?? ""
        if let dot = s.lastIndex(of: "."), Int(s[s.index(after: dot)...]) != nil { return String(s[..<dot]) }
        return s
    }
}

// MARK: - 書き出し

public enum OtioExporter {

    /// 書き出せなかった(OTIO に表せなかった)クリップ。
    public struct Dropped: Equatable {
        public var label: String
        public var reason: String
        public init(label: String, reason: String) { self.label = label; self.reason = reason }
    }

    public struct Report: Equatable {
        /// 書けたクリップ数。
        public var clipCount: Int = 0
        /// 書けなかったクリップ(タイムライン上は Gap にして位置を保つ)。
        public var dropped: [Dropped] = []
        /// クリップは書いたが、OTIO に表せず落ちた機能の件数(エフェクト・トランジション・キーフレーム等)。
        public var droppedFeatures: [String: Int] = [:]
        public var notes: [String] = []
        public init() {}
        public var hasLoss: Bool { !dropped.isEmpty || !droppedFeatures.isEmpty }
        public var summaryLines: [String] {
            var lines = [String(format: L10n.t("書き出し: %d クリップ"), clipCount)]
            for d in dropped { lines.append(String(format: L10n.t("書き出せませんでした %@: %@"), d.label, L10n.t(d.reason))) }
            for (k, v) in droppedFeatures.sorted(by: { $0.key < $1.key }) {
                lines.append(String(format: L10n.t("OTIO に表せず落ちた要素 %@: %d 件"), L10n.t(k), v))
            }
            for n in notes { lines.append(String(format: L10n.t("注記: %@"), L10n.t(n))) }
            return lines
        }
    }

    public struct Output {
        public var data: Data
        public var report: Report
        public init(data: Data, report: Report) { self.data = data; self.report = report }
    }

    static func label(_ clip: Clip) -> String {
        if let src = clip.src, !src.isEmpty { return XmemlText.displayName(for: src) }
        if let t = clip.text, !t.isEmpty { return String(t.prefix(20)) }
        return "\(clip.type.rawValue) クリップ"
    }

    public static func export(project: Project, name: String = "MovieCut") -> Output {
        var report = Report()
        let rate = project.frameRate.value
        func frames(_ s: Double) -> Int { XmemlText.frames(s, fpsValue: rate) }

        var otioTracks: [[String: Any]] = []
        var droppedClipTypes: [String: Int] = [:]

        for (ti, track) in project.tracks.enumerated() {
            // 種別ごとに振り分ける(1 つの MovieCut トラックが映像と音声を両方持つことがある)。
            var visual: [Clip] = []
            var audio: [Clip] = []
            for clip in track.clips {
                if clip.type == .video || clip.type == .image { visual.append(clip) }
                else if clip.type == .audio { audio.append(clip) }
                else {
                    report.dropped.append(Dropped(label: label(clip), reason: "OTIO で表せないクリップ(\(clip.type.rawValue))のため、空き(Gap)にしました"))
                    droppedClipTypes[clip.type.rawValue, default: 0] += 1
                }
            }
            // 表せないクリップの位置は Gap で保つ必要はない(クリップ間の空きは Gap で自然に表す)。
            for (kind, clips) in [("Video", visual), ("Audio", audio)] where !clips.isEmpty {
                let sorted = clips.sorted { $0.start < $1.start }
                // 重なるクリップは別レーンに分ける(OTIO のトラックは直列なので)。
                var lanes: [[Clip]] = []
                var laneEnd: [Int] = []
                for c in sorted {
                    let s = frames(c.start)
                    if let i = laneEnd.firstIndex(where: { $0 <= s }) {
                        lanes[i].append(c); laneEnd[i] = s + frames(c.duration)
                    } else {
                        lanes.append([c]); laneEnd.append(s + frames(c.duration))
                    }
                }
                if lanes.count > 1 {
                    report.notes.append("トラック「\(track.name)」は重なるクリップがあるため、OTIO では \(lanes.count) 本のトラックに分けました(読み込み時に元のトラックへ戻ります)")
                }
                for (li, laneClips) in lanes.enumerated() {
                    var children: [[String: Any]] = []
                    var cursor = 0
                    for clip in laneClips {
                        let s = frames(clip.start)
                        if s > cursor {
                            children.append(["OTIO_SCHEMA": "Gap.1", "name": "", "source_range": OtioJSON.timeRange(startFrames: 0, durationFrames: s - cursor, rate: rate),
                                             "effects": [], "markers": [], "metadata": [String: Any](), "enabled": true])
                        }
                        let d = max(1, frames(clip.duration))
                        children.append(clipJSON(clip, rate: rate, frames: frames, report: &report, durationFrames: d))
                        cursor = max(cursor, s + d)
                        report.clipCount += 1
                    }
                    let enabled = kind == "Video" ? !track.isHidden : !track.isMuted
                    let baseName = track.name.isEmpty ? "\(kind) \(ti + 1)" : track.name
                    let tname = li == 0 ? baseName : "\(baseName) (\(li + 1))"
                    otioTracks.append([
                        "OTIO_SCHEMA": "Track.1", "name": tname, "kind": kind,
                        "source_range": NSNull(), "effects": [], "markers": [],
                        "enabled": enabled, "children": children,
                        "metadata": ["moviecut": ["trackIndex": ti, "trackName": track.name, "lane": li] as [String: Any]],
                    ])
                }
            }
        }

        var markers: [[String: Any]] = []
        for m in project.markers {
            markers.append(["OTIO_SCHEMA": "Marker.2", "name": m.name, "color": "GREEN",
                            "marked_range": OtioJSON.timeRange(startFrames: frames(m.time), durationFrames: 0, rate: rate),
                            "comment": "", "metadata": [String: Any]()])
        }
        if !project.markers.isEmpty { report.notes.append("マーカー \(project.markers.count) 件をタイムラインのマーカーとして書きました(色は既定)") }

        var mc: [String: Any] = ["exporter": "MovieCut", "width": project.width, "height": project.height, "fps": project.fps, "bg": project.bg]
        if !droppedClipTypes.isEmpty { mc["droppedClips"] = droppedClipTypes }
        if !report.droppedFeatures.isEmpty { mc["droppedFeatures"] = report.droppedFeatures }

        let timeline: [String: Any] = [
            "OTIO_SCHEMA": "Timeline.1", "name": name, "global_start_time": NSNull(),
            "metadata": ["moviecut": mc],
            "tracks": ["OTIO_SCHEMA": "Stack.1", "name": "tracks", "source_range": NSNull(), "effects": [],
                       "markers": markers, "enabled": true, "metadata": [String: Any](), "children": otioTracks],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return Output(data: data, report: report)
    }

    private static func clipJSON(_ clip: Clip, rate: Double, frames: (Double) -> Int, report: inout Report, durationFrames: Int) -> [String: Any] {
        var features: [String] = []
        var speed = 1.0
        if clip.rampPoints != nil || clip.effectiveReverse || clip.isFreeze {
            features.append("速度ランプ・逆再生・フリーズ")
        } else {
            speed = clip.effectiveSpeed
        }
        if !clip.effects.isEmpty { features.append("エフェクト") }
        if !clip.keyframes.isEmpty { features.append("キーフレーム") }
        if clip.transitionIn != nil || clip.transitionOut != nil { features.append("トランジション") }
        if clip.fadeIn != nil || clip.fadeOut != nil { features.append("音声フェード") }
        for f in features { report.droppedFeatures[f, default: 0] += 1 }

        let srcStart = frames(clip.offset)
        let srcDur = max(1, Int((Double(durationFrames) * speed).rounded()))
        var mc: [String: Any] = ["id": clip.id]
        if let v = clip.volume { mc["volume"] = v }
        if let v = clip.opacity { mc["opacity"] = v }
        if let v = clip.x { mc["x"] = v }
        if let v = clip.y { mc["y"] = v }
        if let v = clip.scale { mc["scale"] = v }
        if clip.isMuted { mc["muted"] = true }
        if !features.isEmpty { mc["droppedFeatures"] = features }

        var effects: [[String: Any]] = []
        if speed != 1 {
            effects.append(["OTIO_SCHEMA": "LinearTimeWarp.1", "name": "", "effect_name": "LinearTimeWarp",
                            "time_scalar": speed, "metadata": [String: Any]()])
        }
        var ref: [String: Any] = ["OTIO_SCHEMA": "MissingReference.1", "name": "", "available_range": NSNull(), "metadata": [String: Any]()]
        if let src = clip.src, !src.isEmpty {
            ref = ["OTIO_SCHEMA": "ExternalReference.1", "name": XmemlText.displayName(for: src),
                   "target_url": XmemlText.pathURL(for: src),
                   "available_range": clip.srcDuration.map { OtioJSON.timeRange(startFrames: 0, durationFrames: frames($0), rate: rate) } ?? NSNull(),
                   "metadata": [String: Any]()]
        }
        return ["OTIO_SCHEMA": "Clip.1", "name": label(clip),
                "source_range": OtioJSON.timeRange(startFrames: srcStart, durationFrames: srcDur, rate: rate),
                "media_reference": ref, "active_media_reference_key": "DEFAULT_MEDIA",
                "effects": effects, "markers": [], "enabled": !clip.isDisabled,
                "metadata": ["moviecut": mc]]
    }

    @discardableResult
    public static func write(project: Project, to url: URL, name: String = "MovieCut") throws -> Report {
        let out = export(project: project, name: name)
        try out.data.write(to: url, options: .atomic)
        return out.report
    }
}

// MARK: - 読み込み

public enum OtioImporter {

    public struct Unsupported: Equatable {
        public var element: String
        public var label: String
        public var reason: String
        public init(element: String, label: String, reason: String) { self.element = element; self.label = label; self.reason = reason }
    }

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

    public struct Output {
        public var project: Project
        public var report: Report
        public init(project: Project, report: Report) { self.project = project; self.report = report }
    }

    public enum ImportError: Error, LocalizedError {
        case malformedJSON(String)
        case notOtio
        public var errorDescription: String? {
            switch self {
            case .malformedJSON(let d): return "JSON として読めませんでした: \(d)"
            case .notOtio: return "OTIO(Timeline)ではありません"
            }
        }
    }

    public static func read(from url: URL) throws -> Output {
        let data = try InputLimits.readFile(url, limit: InputLimits.maxFcpXmlBytes, what: "OTIO")
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> Output {
        let any: Any
        do { any = try JSONSerialization.jsonObject(with: data) }
        catch { throw ImportError.malformedJSON(error.localizedDescription) }
        guard let root = any as? [String: Any] else { throw ImportError.notOtio }
        var conv = Converter()
        return try conv.convert(root)
    }

    private struct Lane {
        var key: Int
        var name: String
        var clips: [Clip] = []
        var hidden = false
        var muted = false
    }

    private struct Converter {
        var report = Report()
        var lanes: [Lane] = []
        var pool: [String] = []
        var syntheticKey = -1

        mutating func unsupported(_ element: String, _ label: String, _ reason: String) {
            report.unsupported.append(Unsupported(element: element, label: label, reason: reason))
        }

        /// 項目の長さ(秒)。source_range 優先、無ければ中身から。
        func itemDuration(_ d: [String: Any]) -> Double {
            let schema = OtioJSON.schemaName(d)
            if schema == "Transition" { return 0 }
            if let r = OtioJSON.range(d["source_range"]) { return r.duration }
            let kids = (d["children"] as? [[String: Any]]) ?? []
            if schema == "Stack" { return kids.map(itemDuration).max() ?? 0 }
            if schema == "Track" { return kids.map(itemDuration).reduce(0, +) }
            if schema == "Clip", let r = OtioJSON.range((d["media_reference"] as? [String: Any])?["available_range"]) { return r.duration }
            return 0
        }

        mutating func convert(_ root: [String: Any]) throws -> Output {
            var stack: [String: Any]
            var meta: [String: Any] = [:]
            var tlName: String?
            switch OtioJSON.schemaName(root) {
            case "Timeline":
                guard let s = root["tracks"] as? [String: Any] else { throw ImportError.notOtio }
                stack = s
                meta = ((root["metadata"] as? [String: Any])?["moviecut"] as? [String: Any]) ?? [:]
                tlName = root["name"] as? String
            case "Stack":
                stack = root
            default:
                throw ImportError.notOtio
            }
            let children = (stack["children"] as? [[String: Any]]) ?? []

            // フレームレート: MovieCut のメタデータ → 最初に見つかった rate。
            var rateFound: Double? = nil
            func scan(_ any: Any) {
                if rateFound != nil { return }
                if let d = any as? [String: Any] {
                    if let r = OtioJSON.number(d["rate"]), r > 0, d["OTIO_SCHEMA"] as? String == "RationalTime.1" { rateFound = r; return }
                    for k in ["global_start_time", "tracks", "source_range", "children", "media_reference", "available_range", "start_time", "duration"] {
                        if let v = d[k] { scan(v) }
                    }
                } else if let a = any as? [Any] { for v in a { scan(v) } }
            }
            scan(root)
            var fps = 30.0
            if let f = OtioJSON.number(meta["fps"]) { fps = f }
            else if let r = rateFound { fps = r } else { report.notes.append("フレームレートが分からないため 30fps として読み込みました") }
            fps = FrameRate.canonical(fps)

            var project = Project()
            project.fps = fps
            if let w = OtioJSON.number(meta["width"]), let h = OtioJSON.number(meta["height"]), w >= 1, h >= 1 {
                project.width = Int(w); project.height = Int(h)
            } else {
                project.width = 1920; project.height = 1080
                report.notes.append("OTIO には画面サイズがないため 1920×1080 として読み込みました")
            }
            if let bg = meta["bg"] as? String { project.bg = bg }

            for (i, node) in children.enumerated() {
                let schema = OtioJSON.schemaName(node)
                let nodeName = (node["name"] as? String) ?? ""
                guard schema == "Track" else {
                    unsupported(schema, nodeName.isEmpty ? "(無名)" : nodeName, "トラック以外の要素(スタック直下)は読み込めません")
                    continue
                }
                convertTrack(node, index: i)
            }

            var tracks: [Track] = []
            for l in lanes {
                var t = Track(name: l.name)
                t.clips = l.clips.sorted { $0.start < $1.start }
                if l.hidden { t.hidden = true }
                if l.muted { t.muted = true }
                tracks.append(t)
            }
            if tracks.isEmpty {
                report.notes.append("トラックがありませんでした")
                tracks = Track.defaultLayers()
            }
            project.tracks = tracks
            project.mediaPool = pool

            for m in (stack["markers"] as? [[String: Any]]) ?? [] {
                if let r = OtioJSON.range(m["marked_range"]) {
                    project.markers.append(Marker(time: r.start, name: (m["name"] as? String) ?? ""))
                    report.convertedCounts["Marker", default: 0] += 1
                }
            }
            if let n = tlName, !n.isEmpty { report.notes.append("タイムライン「\(n)」を読み込みました") }
            return Output(project: project, report: report)
        }

        mutating func convertTrack(_ node: [String: Any], index: Int) {
            let kind = ((node["kind"] as? String) ?? "Video")
            let isAudio = kind.lowercased() == "audio"
            if kind.lowercased() != "audio" && kind.lowercased() != "video" {
                report.notes.append("トラック種別「\(kind)」は映像として読み込みました")
            }
            let mcMeta = ((node["metadata"] as? [String: Any])?["moviecut"] as? [String: Any]) ?? [:]
            let key: Int
            if let ti = OtioJSON.number(mcMeta["trackIndex"]) { key = Int(ti) } else { key = syntheticKey; syntheticKey -= 1 }
            let name = (mcMeta["trackName"] as? String) ?? ((node["name"] as? String) ?? "")
            var li = lanes.firstIndex { $0.key == key } ?? -1
            if li < 0 { lanes.append(Lane(key: key, name: name)); li = lanes.count - 1 }
            if (node["enabled"] as? Bool) == false {
                if isAudio { lanes[li].muted = true } else { lanes[li].hidden = true }
            }

            var cursor = 0.0
            for item in (node["children"] as? [[String: Any]]) ?? [] {
                let schema = OtioJSON.schemaName(item)
                let label = ((item["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }) ?? schema
                switch schema {
                case "Gap":
                    cursor += itemDuration(item)
                case "Clip":
                    if let clip = convertClip(item, start: cursor, isAudio: isAudio, label: label) {
                        lanes[li].clips.append(clip)
                        report.convertedCounts[isAudio ? "AudioClip" : "VideoClip", default: 0] += 1
                    }
                    cursor += itemDuration(item) / max(0.0001, timeScalar(item))
                case "Transition":
                    unsupported("Transition", label, "トランジションは読み込めません(前後のクリップの位置・長さはそのまま読みます)")
                default:
                    unsupported(schema, label, "対応していない要素です(ネストしたスタック・トラック等)。長さ分の空きとして扱います")
                    cursor += itemDuration(item)
                }
            }
        }

        func timeScalar(_ item: [String: Any]) -> Double {
            for e in (item["effects"] as? [[String: Any]]) ?? [] where OtioJSON.schemaName(e) == "LinearTimeWarp" {
                if let s = OtioJSON.number(e["time_scalar"]), s > 0 { return s }
            }
            return 1
        }

        mutating func convertClip(_ item: [String: Any], start: Double, isAudio: Bool, label: String) -> Clip? {
            let ref = item["media_reference"] as? [String: Any]
            let avail = OtioJSON.range(ref?["available_range"])
            let sr = OtioJSON.range(item["source_range"])
            guard let srcDur = sr?.duration ?? avail?.duration, srcDur > 0 else {
                unsupported("Clip", label, "長さ(source_range / available_range)がないため読み込めません")
                return nil
            }
            let refSchema = ref.map { OtioJSON.schemaName($0) } ?? "MissingReference"
            guard refSchema == "ExternalReference", let url = ref?["target_url"] as? String, !url.isEmpty else {
                unsupported("Clip", label, "素材参照が ExternalReference ではない(\(refSchema))ため読み込めません")
                return nil
            }
            var scalar = timeScalar(item)
            for e in (item["effects"] as? [[String: Any]]) ?? [] {
                let s = OtioJSON.schemaName(e)
                if s == "LinearTimeWarp" { continue }
                unsupported(s, label, "エフェクトは読み込めません")
            }
            if scalar < 0.25 || scalar > 4 {
                unsupported("LinearTimeWarp", label, "速度 \(scalar) は 0.25〜4 の範囲外のため等倍で読み込みました")
                scalar = 1
            }
            if let ms = item["markers"] as? [Any], !ms.isEmpty {
                unsupported("Marker", label, "クリップ上のマーカーは読み込めません")
            }
            let src = XmemlText.path(fromPathURL: url)
            var clip = Clip()
            clip.type = isAudio ? .audio : (XmemlText.isStillImagePath(src) ? .image : .video)
            clip.src = src
            clip.start = start
            clip.duration = srcDur / scalar
            clip.offset = sr?.start ?? 0
            if let a = avail { clip.srcDuration = a.duration }
            if scalar != 1 { clip.speed = scalar }
            if (item["enabled"] as? Bool) == false { clip.disabled = true }
            let mc = ((item["metadata"] as? [String: Any])?["moviecut"] as? [String: Any]) ?? [:]
            if let v = OtioJSON.number(mc["volume"]) { clip.volume = v }
            if let v = OtioJSON.number(mc["opacity"]) { clip.opacity = v }
            if let v = OtioJSON.number(mc["x"]) { clip.x = v }
            if let v = OtioJSON.number(mc["y"]) { clip.y = v }
            if let v = OtioJSON.number(mc["scale"]) { clip.scale = v }
            if (mc["muted"] as? Bool) == true { clip.muted = true }
            if let id = mc["id"] as? String, !id.isEmpty { clip.id = id }
            if !pool.contains(src) { pool.append(src) }
            return clip
        }
    }
}
