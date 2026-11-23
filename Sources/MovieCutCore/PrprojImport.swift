import Foundation
import Compression

// MARK: - Premiere Pro プロジェクト(.prproj)読み込み
//
// ## 形式の根拠(推測で書いていない。2026-11-19 に公開資料と実構造の調査で確認)
// - .prproj は gzip 圧縮された UTF-8 XML が実体(マジック 1F 8B)。圧縮されていない
//   素の XML のこともある(先頭が `<?xml`)。ルートは `<PremiereData Version="3">`。
//   根拠: 米国国立公文書館の形式登録 NF00818、Adobe コミュニティでの Adobe 側回答、
//   実ファイル調査に基づく prproj-parser の形式ノート(docs/prproj-format)。
// - 中身は「入れ子の木」ではなく、`<PremiereData>` 直下に平らに並んだオブジェクトの
//   グラフ。各オブジェクトは `ObjectID`(整数)か `ObjectUID`(UUID)を持ち、他の要素からは
//   `ObjectRef` / `ObjectURef` 属性で参照される。ObjectID は直下の要素の間でのみ一意で、
//   深く入れ子になった UI 設定内の同名 ID と衝突しうるため、索引は直下の要素だけから作る。
// - 時刻はすべて tick 単位で、254,016,000,000 tick = 1 秒(全レート共通の定数)。
//   シーケンスのフレームレートは VideoTrackGroup の `<FrameRate>`(1 コマあたりの tick 数)。
// - 参照の連鎖(タイムラインの 1 クリップから素材ファイルまで):
//   Sequence →(TrackGroups の Index 0=映像 / 1=音声 / 2=データ)→ VideoTrackGroup /
//   AudioTrackGroup →(Tracks)→ VideoClipTrack / AudioClipTrack →(ClipItems/TrackItems)→
//   VideoClipTrackItem / AudioClipTrackItem(ClipTrackItem/TrackItem の Start・End が配置)→
//   SubClip(表示名と Clip・MasterClip への参照)→ VideoClip / AudioClip(Clip の InPoint・
//   OutPoint・PlaybackSpeed が素材内の使用範囲と速度)→ VideoMediaSource / AudioMediaSource
//   →(MediaSource/Media)→ Media(FilePath が実パス、Start が素材の開始タイムコード tick)。
//   素材内の相対位置は InPoint − Media の Start で求める(カメラ素材は開始タイムコードが
//   1 時間等になり、InPoint がそのままでは巨大な値になるため)。
// - 基本変換はクリップの ComponentOwner → VideoComponentChain の中の
//   VideoFilterComponent(MatchName `AE.ADBE Motion` / `AE.ADBE Opacity`)の静止値から取る。
//   Motion のパラメータは ParameterID 1=Position(シーケンス画面に対する割合の点、
//   `x:y` 形式)/ 2=Scale(パーセント)/ 3=Scale Width / 4=Uniform Scale / 5=Rotation(度)/
//   6=Anchor Point(素材画面に対する割合)。Opacity は ParameterID 1=Opacity(パーセント)。
//   音量は MatchName が `Internal Volume` で始まるコンポーネントの Level
//   (線形値で 1.0 = +15dB。0dB は約 0.17783)。
//   パラメータの静止値は `<StartKeyframe>` の「時刻,値,...」の値部分、キーフレーム列は
//   `<Keyframes>` に文字列で入る(本実装ではキーフレームは運ばず静止値だけを使い、
//   あったことはレポートに残す)。
//
// ## 対応範囲(詳細は docs/Prproj読み込み.md)
// - 読み込む: 最初のシーケンス(クリップのあるもの優先)のカット・配置・素材参照・
//   基本変換(位置/スケール/回転/不透明度)・音量・一定速度と逆再生・シーケンスマーカー・
//   トラックのロック/ミュート/非表示・クリップの無効化・調整レイヤー。
// - 対応できない要素(他のシーケンス、トランジション、Motion/Opacity/Volume 以外の
//   エフェクト、ネストしたシーケンス、キーフレーム、速度ランプ、字幕トラック、
//   生成素材など)は、FcpXmlImporter と同じ作法で理由つきの変換レポートに必ず残す。
// - 実 Premiere Pro のファイルでの検証は未実施(自作フィクスチャと公開資料の実例構造で
//   検証)。バージョン差の注意は docs/Prproj読み込み.md に明記した。

/// Premiere Pro プロジェクト(.prproj)を MovieCut の `Project` へ変換するインポーター。
public enum PrprojImporter {

    /// 1 秒あたりの tick 数(Premiere の全時刻の単位)。
    public static let ticksPerSecond: Double = 254_016_000_000

    /// 読み込みで取りこぼした要素。
    public struct Unsupported: Equatable {
        public var element: String
        public var label: String
        public var reason: String
        public init(element: String, label: String, reason: String) {
            self.element = element; self.label = label; self.reason = reason
        }
    }

    /// 読み込みレポート(FcpXmlImporter.Report と同じ形)。
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
        case emptyFile
        case gzipFailed(String)
        case malformedXML(String)
        case notPrproj
        case noSequence

        public var errorDescription: String? {
            switch self {
            case .emptyFile: return "ファイルが空です"
            case .gzipFailed(let detail): return "gzip の展開に失敗しました: \(detail)"
            case .malformedXML(let detail): return "XML として読めませんでした: \(detail)"
            case .notPrproj: return "Premiere Pro プロジェクト(.prproj)ではありません(PremiereData 要素がありません)"
            case .noSequence: return "シーケンスが見つかりませんでした"
            }
        }
    }

    // MARK: 入口

    /// .prproj のデータ(gzip 圧縮または素の XML)をプロジェクトへ変換する。
    public static func parse(data: Data) throws -> Output {
        guard !data.isEmpty else { throw ImportError.emptyFile }
        let xmlData: Data
        if data.count >= 2, data[0] == 0x1f, data[1] == 0x8b {
            xmlData = try gunzip(data)
        } else {
            xmlData = data
        }
        let builder = FcpXmlImporter.XmlTreeBuilder()
        let parser = XMLParser(data: xmlData)
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            throw ImportError.malformedXML(parser.parserError?.localizedDescription ?? "解析に失敗しました")
        }
        guard root.name == "PremiereData" else { throw ImportError.notPrproj }
        var converter = Converter(root: root)
        return try converter.convert()
    }

    /// ファイルから読み込む。
    public static func read(from url: URL) throws -> Output {
        let data = try InputLimits.readFile(url, limit: InputLimits.maxPrprojBytes, what: "Premiere プロジェクト")
        return try parse(data: data)
    }

    // MARK: gzip 展開

    /// 展開後の上限(256MiB)。gzip 爆弾でメモリを使い切らないための上限。
    static let maxXMLBytes = 256 << 20

    /// gzip(RFC 1952)を展開する。ヘッダを解析して生の DEFLATE 部分を取り出し、
    /// Compression の COMPRESSION_ZLIB(生 DEFLATE、RFC 1951)で展開する。
    /// 末尾の CRC32 と ISIZE を自前で照合し、壊れたデータを黙って通さない。
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b else {
            throw ImportError.gzipFailed("gzip のマジックがありません")
        }
        guard bytes[2] == 0x08 else { throw ImportError.gzipFailed("deflate 以外の圧縮方式です") }
        var idx = 10
        let flg = bytes[3]
        if flg & 0x04 != 0 { // FEXTRA
            guard idx + 2 <= bytes.count else { throw ImportError.gzipFailed("ヘッダが途中で切れています") }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if flg & 0x08 != 0 { // FNAME
            while idx < bytes.count, bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flg & 0x10 != 0 { // FCOMMENT
            while idx < bytes.count, bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flg & 0x02 != 0 { idx += 2 } // FHCRC
        guard idx < bytes.count - 8 else { throw ImportError.gzipFailed("本体がありません") }

        let n = bytes.count
        let storedCRC = UInt32(bytes[n - 8]) | (UInt32(bytes[n - 7]) << 8) | (UInt32(bytes[n - 6]) << 16) | (UInt32(bytes[n - 5]) << 24)
        let isize = Int(bytes[n - 4]) | (Int(bytes[n - 3]) << 8) | (Int(bytes[n - 2]) << 16) | (Int(bytes[n - 1]) << 24)
        guard isize > 0, isize <= maxXMLBytes else {
            throw ImportError.gzipFailed("展開後のサイズ(\(isize) バイト)が想定外です")
        }
        let payload = Data(bytes[idx..<(n - 8)])
        var dst = Data(count: isize)
        let written = dst.withUnsafeMutableBytes { dp in
            payload.withUnsafeBytes { sp in
                compression_decode_buffer(dp.baseAddress!.assumingMemoryBound(to: UInt8.self), isize,
                                          sp.baseAddress!.assumingMemoryBound(to: UInt8.self), payload.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == isize else {
            throw ImportError.gzipFailed("deflate の展開に失敗しました(壊れている可能性があります)")
        }
        guard crc32(dst) == storedCRC else {
            throw ImportError.gzipFailed("CRC32 が一致しません(壊れている可能性があります)")
        }
        return dst
    }

    /// CRC32(IEEE、gzip の末尾の照合用)。
    static func crc32(_ data: Data) -> UInt32 {
        var table: [UInt32] = []
        table.reserveCapacity(256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
            table.append(c)
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: 変換の本体

    private struct Converter {
        typealias Node = FcpXmlImporter.XmlNode

        var root: Node
        var report = Report()
        /// PremiereData 直下の要素だけの索引(ObjectID / ObjectUID)。
        var byID: [String: Node] = [:]
        var byUID: [String: Node] = [:]
        var notedWindowsPath = false
        var notedClipMarkers = false

        init(root: Node) {
            self.root = root
            for child in root.children {
                if let id = child.attributes["ObjectID"], byID[id] == nil { byID[id] = child }
                if let uid = child.attributes["ObjectUID"], byUID[uid] == nil { byUID[uid] = child }
            }
        }

        // MARK: 小さな道具

        /// 参照要素(ObjectRef / ObjectURef を持つ空要素)を実体へ解決する。参照でなければ自分自身。
        func deref(_ node: Node?) -> Node? {
            guard let node else { return nil }
            if let ref = node.attributes["ObjectRef"] { return byID[ref] }
            if let ref = node.attributes["ObjectURef"] { return byUID[ref] }
            return node
        }

        /// 子要素を参照解決して返す。
        func ref(_ node: Node?, _ name: String) -> Node? { deref(node?.first(name)) }

        /// 子要素のテキスト。
        func text(_ node: Node?, _ name: String) -> String? { node?.str(name) }

        /// 子要素の tick 値(整数)。
        func ticks(_ node: Node?, _ name: String) -> Int64? {
            guard let s = node?.str(name) else { return nil }
            if let v = Int64(s) { return v }
            return Double(s).flatMap { d in
                (d.isFinite && abs(d) < 9.223372036854776e18) ? Int64(d) : nil
            }
        }

        /// Index 属性順に並べたリスト要素の子(参照解決済み)。
        func listEntries(_ container: Node?) -> [Node] {
            guard let container else { return [] }
            let sorted = container.children.sorted {
                (Int($0.attributes["Index"] ?? "") ?? Int.max) < (Int($1.attributes["Index"] ?? "") ?? Int.max)
            }
            return sorted.compactMap { deref($0) }
        }

        func seconds(_ ticks: Int64) -> Double { Double(ticks) / PrprojImporter.ticksPerSecond }

        // MARK: 全体

        mutating func convert() throws -> Output {
            if let v = root.attributes["Version"], v != "3" {
                report.notes.append("PremiereData のバージョンが \(v) でした(想定は 3)。読める範囲で読み込みます")
            }
            // プロジェクト要素(形式バージョンの手がかり)。
            if let proj = root.children.first(where: { $0.name == "Project" && $0.attributes["ObjectID"] != nil }),
               let v = proj.attributes["Version"] {
                report.notes.append("Premiere のプロジェクト形式バージョン \(v) のファイルです")
            }
            let sequences = root.children.filter { $0.name == "Sequence" }
            guard !sequences.isEmpty else { throw ImportError.noSequence }

            // 主シーケンス: クリップのある最初のもの。無ければ最初のもの。
            var primaryIndex = 0
            for (i, seq) in sequences.enumerated() where sequenceClipCount(seq) > 0 {
                primaryIndex = i
                break
            }
            for (i, seq) in sequences.enumerated() where i != primaryIndex {
                report.unsupported.append(Unsupported(
                    element: "Sequence", label: seq.str("Name") ?? "シーケンス \(i + 1)",
                    reason: "MovieCut のプロジェクトは 1 本のタイムラインのため、主シーケンス以外は読み込んでいません"))
            }
            let project = convertSequence(sequences[primaryIndex])
            return Output(project: project, report: report)
        }

        /// シーケンスのクリップ総数(主シーケンス選び用。大まかに数える)。
        func sequenceClipCount(_ seq: Node) -> Int {
            var count = 0
            for group in trackGroups(seq) {
                for track in trackNodes(of: group.node) {
                    count += listEntries(track.first("ClipTrack")?.first("ClipItems")?.first("TrackItems")).count
                }
            }
            return count
        }

        /// Sequence の TrackGroups を (種別, グループ要素) で返す。種別はグループ要素の名前で判定する。
        func trackGroups(_ seq: Node) -> [(kind: String, node: Node)] {
            guard let groups = seq.first("TrackGroups") else { return [] }
            var out: [(String, Node)] = []
            for entry in groups.all("TrackGroup") {
                guard let group = deref(entry.first("Second")) else { continue }
                out.append((group.name, group))
            }
            return out
        }

        /// トラックグループ内のトラック要素列(Index 順)。
        func trackNodes(of group: Node) -> [Node] {
            listEntries(group.first("TrackGroup")?.first("Tracks"))
        }

        // MARK: シーケンス

        mutating func convertSequence(_ seq: Node) -> Project {
            let groups = trackGroups(seq)
            let videoGroup = groups.first { $0.kind == "VideoTrackGroup" }?.node
            let audioGroup = groups.first { $0.kind == "AudioTrackGroup" }?.node
            let dataGroup = groups.first { $0.kind == "DataTrackGroup" }?.node

            var project = Project()
            // フレームレート(VideoTrackGroup の FrameRate = 1 コマの tick 数)。
            if let tpf = ticks(videoGroup?.first("TrackGroup"), "FrameRate"), tpf > 0 {
                project.fps = FrameRate.canonical(PrprojImporter.ticksPerSecond / Double(tpf))
            } else {
                project.fps = 30
                report.notes.append("シーケンスのフレームレートが分からないため 30fps として読み込みました")
            }
            // 画面サイズ(VideoTrackGroup の FrameRect = 左,上,右,下)。
            if let rectText = text(videoGroup, "FrameRect") {
                let parts = rectText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 4, parts[2] > parts[0], parts[3] > parts[1] {
                    project.width = parts[2] - parts[0]
                    project.height = parts[3] - parts[1]
                } else {
                    report.notes.append("シーケンスの画面サイズが読めないため 1920×1080 として読み込みました")
                    project.width = 1920; project.height = 1080
                }
            } else {
                report.notes.append("シーケンスの画面サイズが分からないため 1920×1080 として読み込みました")
                project.width = 1920; project.height = 1080
            }
            // シーケンスの開始タイムコード(ゼロ点)は MovieCut のタイムラインに無い概念。
            if let zero = ticks(seq.first("Node")?.first("Properties"), "MZ.ZeroPoint"), zero > 0 {
                report.notes.append("シーケンスの開始タイムコードは取り込めないため、タイムラインは 0 秒から始まります")
            }

            var tracks: [Track] = []
            var pool: [String] = []
            if let videoGroup {
                for (i, trackNode) in trackNodes(of: videoGroup).enumerated() {
                    tracks.append(convertTrack(trackNode, isAudio: false, index: i, pool: &pool))
                }
            }
            if let audioGroup {
                for (i, trackNode) in trackNodes(of: audioGroup).enumerated() {
                    tracks.append(convertTrack(trackNode, isAudio: true, index: i, pool: &pool))
                }
            }
            if let dataGroup {
                var captionCount = 0
                for trackNode in trackNodes(of: dataGroup) {
                    captionCount += listEntries(trackNode.first("ClipTrack")?.first("ClipItems")?.first("TrackItems")).count
                }
                if captionCount > 0 {
                    report.unsupported.append(Unsupported(
                        element: "CaptionDataClipTrack", label: "字幕トラック",
                        reason: "字幕(キャプション)トラックは読み込んでいません(\(captionCount) 件)"))
                }
            }
            if tracks.isEmpty {
                report.notes.append("トラックがありませんでした")
                tracks = Track.defaultLayers()
            }
            project.tracks = tracks
            project.mediaPool = pool
            project.markers = convertMarkers(seq)
            if let name = seq.str("Name") {
                report.notes.append("シーケンス「\(name)」を読み込みました")
            }
            return project
        }

        // MARK: マーカー

        /// シーケンスのマーカー(MarkerOwner/Markers の各 Marker の DVAMarker JSON)。
        mutating func convertMarkers(_ seq: Node) -> [Marker] {
            guard let markersNode = seq.first("MarkerOwner")?.first("Markers") else { return [] }
            var out: [Marker] = []
            for entry in markersNode.children {
                let markerNode = deref(entry.first("Second")) ?? deref(entry)
                guard let jsonText = markerNode?.str("DVAMarker"),
                      let data = jsonText.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let d = obj["DVAMarker"] as? [String: Any] else {
                    report.unsupported.append(Unsupported(
                        element: "Marker", label: "マーカー",
                        reason: "DVAMarker の JSON が読めなかったため読み込んでいません"))
                    continue
                }
                func jsonTicks(_ key: String) -> Int64? {
                    guard let v = d[key] else { return nil }
                    if let dict = v as? [String: Any], let t = dict["ticks"] as? NSNumber { return t.int64Value }
                    if let n = v as? NSNumber { return n.int64Value }
                    return nil
                }
                guard let startTicks = jsonTicks("mStartTime") else {
                    report.unsupported.append(Unsupported(
                        element: "Marker", label: "マーカー",
                        reason: "時刻が入っていなかったため読み込んでいません"))
                    continue
                }
                let name = (d["mName"] as? String) ?? (d["mComment"] as? String) ?? ""
                if let type = d["mType"] as? String, type != "Comment" {
                    report.notes.append("マーカーの種類「\(type)」は MovieCut では通常のマーカーとして読み込みました")
                }
                out.append(Marker(time: seconds(startTicks), name: name))
            }
            return out.sorted { $0.time < $1.time }
        }

        // MARK: トラック

        mutating func convertTrack(_ trackNode: Node, isAudio: Bool, index: Int, pool: inout [String]) -> Track {
            var track = Track(name: isAudio ? "A\(index + 1)" : "V\(index + 1)")
            let clipTrack = trackNode.first("ClipTrack")
            let meta = clipTrack?.first("Track")
            if text(meta, "IsLocked") == "true" { track.locked = true }
            if text(meta, "IsMuted") == "true" {
                if isAudio { track.muted = true } else { track.hidden = true }
            }
            // トランジション(トラックの TransitionItems に並ぶ)。
            for item in listEntries(clipTrack?.first("TransitionItems")?.first("TrackItems")) {
                let tt = item.first("TransitionTrackItem")
                let name = text(tt, "DisplayName") ?? text(item, "MatchName") ?? text(tt, "MatchName") ?? "トランジション"
                report.unsupported.append(Unsupported(
                    element: "TransitionTrackItem", label: name,
                    reason: "トランジションは読み込まず、カットとして扱いました"))
            }
            var clips: [Clip] = []
            for item in listEntries(clipTrack?.first("ClipItems")?.first("TrackItems")) {
                if let clip = convertClipItem(item, isAudio: isAudio, pool: &pool) {
                    clips.append(clip)
                }
            }
            track.clips = clips.sorted { $0.start < $1.start }
            return track
        }

        // MARK: クリップ

        mutating func convertClipItem(_ item: Node, isAudio: Bool, pool: inout [String]) -> Clip? {
            let cti = item.first("ClipTrackItem") ?? item
            let sub = ref(cti, "SubClip")
            let label = sub?.str("Name") ?? "クリップ"
            guard let ti = cti.first("TrackItem"), let endTicks = ticks(ti, "End") else {
                report.unsupported.append(Unsupported(
                    element: item.name, label: label,
                    reason: "配置(End)が読めなかったため読み込んでいません"))
                return nil
            }
            let startTicks = ticks(ti, "Start") ?? 0 // 2026 形式では Start=0 のとき要素ごと省略される
            guard endTicks > startTicks else {
                report.unsupported.append(Unsupported(
                    element: item.name, label: label,
                    reason: "長さが 0 のため読み込んでいません"))
                return nil
            }

            // SubClip → Clip(VideoClip/AudioClip)。無ければ MasterClip の Clips から補う。
            var vc = ref(sub, "Clip")
            let master = ref(sub, "MasterClip")
            if vc == nil, let master {
                let candidates = listEntries(master.first("Clips"))
                vc = candidates.first { $0.name == (isAudio ? "AudioClip" : "VideoClip") } ?? candidates.first
            }
            let clipBody = vc?.first("Clip")

            var clip = Clip()
            clip.start = seconds(startTicks)
            clip.duration = seconds(endTicks - startTicks)
            if text(cti, "IsMuted") == "true" { clip.disabled = true }

            // 調整レイヤー(素材を持たない特殊な MasterClip)。
            if text(master, "IsAdjustmentLayer") == "true" {
                clip.type = .adjustment
                report.convertedCounts[clip.type.rawValue, default: 0] += 1
                return clip
            }

            // 素材の解決: Clip → Source → MediaSource → Media。
            guard let source = ref(clipBody, "Source") else {
                report.notes.append("クリップ「\(label)」には素材の参照がないため、参照なしのクリップとして読み込みました")
                clip.type = isAudio ? .audio : .video
                report.convertedCounts[clip.type.rawValue, default: 0] += 1
                return clip
            }
            if source.name.hasSuffix("SequenceSource") {
                report.unsupported.append(Unsupported(
                    element: "SequenceSource", label: label,
                    reason: "入れ子(ネスト)になったシーケンスは読み込んでいません"))
                return nil
            }
            guard source.name.hasSuffix("MediaSource") else {
                report.unsupported.append(Unsupported(
                    element: source.name, label: label,
                    reason: "対応していない素材の種類のため読み込んでいません"))
                return nil
            }
            guard let media = ref(source.first("MediaSource"), "Media") else {
                report.unsupported.append(Unsupported(
                    element: "Media", label: label,
                    reason: "素材(Media)が見つからなかったため読み込んでいません"))
                return nil
            }

            // 実パスの解決。生成素材(カラーマット等)は FilePath が内部 ID の数字だけになる。
            let title = media.str("Title") ?? label
            var src = media.str("FilePath") ?? media.str("ActualMediaFilePath")
            if let s = src, !s.contains("/"), !s.contains("\\"), Int64(s) != nil {
                report.unsupported.append(Unsupported(
                    element: "Media", label: title,
                    reason: "実ファイルを持たない生成素材のため読み込んでいません"))
                return nil
            }
            if src == nil, let rel = media.str("RelativePath") {
                src = rel
                report.notes.append("素材「\(title)」は絶対パスが無いため、相対パス「\(rel)」で読み込みました")
            }
            if let s = src {
                var resolved = s
                if resolved.hasPrefix("file://") { resolved = XmemlText.path(fromPathURL: resolved) }
                if resolved.contains("\\") {
                    resolved = resolved.replacingOccurrences(of: "\\", with: "/")
                    if !notedWindowsPath {
                        notedWindowsPath = true
                        report.notes.append("Windows 形式の素材パスはスラッシュに変換して読み込みました(ドライブ文字など、場所の対応付けは素材の再リンクで直してください)")
                    }
                }
                clip.src = resolved
                if !pool.contains(resolved) { pool.append(resolved) }
            } else {
                report.notes.append("クリップ「\(label)」の素材パスが空のため、参照なしのクリップとして読み込みました")
            }

            // 素材の長さと開始位置(開始タイムコード)。
            let stream = ref(media, isAudio ? "AudioStream" : "VideoStream")
            let isStill = text(stream, "IsStill") == "true"
            if let d = ticks(stream, "Duration"), d > 0 {
                clip.srcDuration = seconds(d)
            } else if let d = ticks(source, "OriginalDuration"), d > 0 {
                clip.srcDuration = seconds(d)
            }
            let mediaStart = ticks(media, "Start") ?? 0

            // 使用範囲(in/out)と速度。
            let inTicks = ticks(clipBody, "InPoint") ?? 0
            if isStill {
                clip.offset = 0
            } else {
                if inTicks < mediaStart {
                    report.notes.append("クリップ「\(label)」の開始点が素材の開始タイムコードより前のため、使用開始を 0 秒として読み込みました")
                }
                clip.offset = seconds(max(0, inTicks - mediaStart))
            }
            let speed = clipBody?.first("PlaybackSpeed").flatMap { Double($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
            if clipBody?.first("TimeRemapping") != nil {
                report.unsupported.append(Unsupported(
                    element: "TimeRemapping", label: label,
                    reason: "速度ランプ(可変速度)は読み込まず、一定速度として扱いました"))
            }
            if speed != 1, speed != 0 {
                var s = abs(speed)
                if s < 0.25 || s > 4 {
                    report.notes.append("クリップ「\(label)」の速度 \(speed) は MovieCut の範囲(0.25〜4)外のため、範囲内に収めて読み込みました")
                    s = min(max(s, 0.25), 4)
                }
                clip.speed = s == 1 ? nil : s
                if speed < 0 { clip.reverse = true }
            }
            if clipBody?.first("MarkerOwner") != nil, !notedClipMarkers {
                notedClipMarkers = true
                report.notes.append("クリップに付けられたマーカーは読み込んでいません(シーケンスのマーカーだけを読み込みます)")
            }

            // 種別。
            if isAudio {
                clip.type = .audio
            } else if isStill || (clip.src.map { XmemlText.isStillImagePath($0) } ?? false) {
                clip.type = .image
            } else {
                clip.type = .video
            }

            applyComponents(cti, to: &clip, label: label)
            report.convertedCounts[clip.type.rawValue, default: 0] += 1
            return clip
        }

        // MARK: エフェクト(Motion / Opacity / Volume だけを取り込む)

        /// パラメータの静止値(StartKeyframe の「時刻,値,...」の値部分)とキーフレームの有無。
        func paramStaticFields(_ param: Node) -> (fields: [String], animated: Bool) {
            let animated = !(param.str("Keyframes") ?? "").isEmpty
            if let sk = param.str("StartKeyframe") {
                let parts = sk.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                return (Array(parts.dropFirst()), animated)
            }
            if let cv = param.str("CurrentValue") {
                return (cv.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }, animated)
            }
            return ([], animated)
        }

        func paramFloat(_ param: Node) -> (value: Double, animated: Bool)? {
            let (fields, animated) = paramStaticFields(param)
            guard let first = fields.first, let v = Double(first) else { return nil }
            return (v, animated)
        }

        /// 点の値: `x:y` が 1 フィールドに入る形と、x と y が別フィールドの形の両方に対応。
        func paramPoint(_ param: Node) -> (x: Double, y: Double, animated: Bool)? {
            let (fields, animated) = paramStaticFields(param)
            guard let first = fields.first else { return nil }
            if let sep = first.firstIndex(of: ":") {
                let xs = String(first[first.startIndex..<sep])
                let ys = String(first[first.index(after: sep)...])
                guard let x = Double(xs), let y = Double(ys) else { return nil }
                return (x, y, animated)
            }
            guard fields.count >= 2, let x = Double(fields[0]), let y = Double(fields[1]) else { return nil }
            return (x, y, animated)
        }

        mutating func applyComponents(_ cti: Node, to clip: inout Clip, label: String) {
            guard let chain = ref(cti.first("ComponentOwner"), "Components") else { return }
            let components = listEntries(chain.first("ComponentChain")?.first("Components"))
            var animatedParams: [String] = []
            for component in components {
                let matchName = component.str("MatchName") ?? component.str("FilterMatchName") ?? ""
                let comp = component.first("Component") ?? component.first("AudioComponent")?.first("Component")
                let display = comp?.str("DisplayName") ?? matchName
                let bypass = text(comp, "Bypass") == "true"
                let params = listEntries(comp?.first("Params"))
                func findParam(id: Int, name: String) -> Node? {
                    params.first { ticks($0, "ParameterID") == Int64(id) }
                        ?? params.first { ($0.str("Name") ?? "").lowercased() == name.lowercased() }
                }
                func noteAnimated(_ paramName: String, _ animated: Bool) {
                    if animated { animatedParams.append(paramName) }
                }

                switch matchName {
                case "AE.ADBE Motion":
                    if bypass {
                        report.notes.append("クリップ「\(label)」の Motion は無効化されていたため、基本変換を読み込んでいません")
                        continue
                    }
                    if let p = findParam(id: 1, name: "Position"), let v = paramPoint(p) {
                        clip.x = v.x; clip.y = v.y; noteAnimated("位置", v.animated)
                    }
                    if let p = findParam(id: 2, name: "Scale"), let v = paramFloat(p) {
                        let s = v.value / 100
                        if s != 1 { clip.scale = s }
                        noteAnimated("スケール", v.animated)
                    }
                    if let p = findParam(id: 3, name: "Scale Width"), let v = paramFloat(p) {
                        let uniform = findParam(id: 4, name: "Uniform Scale").map { (paramStaticFields($0).fields.first ?? "") == "true" } ?? true
                        if !uniform, v.value != (clip.scale ?? 1) * 100 {
                            report.unsupported.append(Unsupported(
                                element: "VideoComponentParam", label: label,
                                reason: "横だけのスケール(Scale Width)は MovieCut に無いため読み込んでいません"))
                        }
                    }
                    if let p = findParam(id: 5, name: "Rotation"), let v = paramFloat(p) {
                        if v.value != 0 { clip.rotation = v.value }
                        noteAnimated("回転", v.animated)
                    }
                    if let p = findParam(id: 6, name: "Anchor Point"), let v = paramPoint(p), v.x != 0.5 || v.y != 0.5 {
                        report.unsupported.append(Unsupported(
                            element: "VideoComponentParam", label: label,
                            reason: "アンカーポイントは MovieCut に無いため読み込んでいません"))
                    }
                case "AE.ADBE Opacity":
                    if bypass {
                        report.notes.append("クリップ「\(label)」の Opacity は無効化されていたため、不透明度を読み込んでいません")
                        continue
                    }
                    if let p = findParam(id: 1, name: "Opacity"), let v = paramFloat(p) {
                        let o = min(max(v.value / 100, 0), 1)
                        if o != 1 { clip.opacity = o }
                        noteAnimated("不透明度", v.animated)
                    }
                    for p in params where (p.str("Name") ?? "").lowercased() == "blend mode" {
                        let (fields, _) = paramStaticFields(p)
                        if let first = fields.first, let mode = Int(first), mode != 18 {
                            report.unsupported.append(Unsupported(
                                element: "VideoComponentParam", label: label,
                                reason: "ブレンドモード(値 \(mode))は読み込んでいません"))
                        }
                    }
                case _ where matchName.hasPrefix("Internal Volume"):
                    if bypass { continue }
                    if let p = findParam(id: 0, name: "Level") ?? findParam(id: 0, name: "Volume"), let v = paramFloat(p) {
                        // Premiere の Level は線形値で 1.0 = +15dB。
                        let gain: Double
                        if v.value <= 0 { gain = 0 } else { gain = pow(10, (20 * log10(v.value) + 15) / 20) }
                        if abs(gain - 1) > 0.0001 { clip.volume = gain }
                        noteAnimated("音量", v.animated)
                    }
                default:
                    if !matchName.isEmpty || !display.isEmpty {
                        report.unsupported.append(Unsupported(
                            element: component.name, label: label,
                            reason: "エフェクト「\(display)」は対応していないため読み込んでいません"))
                    }
                }
            }
            if !animatedParams.isEmpty {
                report.notes.append("クリップ「\(label)」の \(animatedParams.joined(separator: "・")) にはキーフレームがありました。静止値だけを読み込んでいます")
            }
        }
    }
}
