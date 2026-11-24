import Foundation

// MARK: - AIラフカット(第 1 版)
//
// タイムラインにある素材クリップの文字起こしを AI に読ませ、ユーザーの指示
// (構成・尺の希望などの自由文)に応じて AI が返した「保持区間の並び」を検証し、
// 新しいシーンとして組み立てるための土台。画面にも Undo にも依存しない純粋な
// 処理と、差し替え可能なプロバイダ境界(`RoughCutProvider`)を持つ。
//
// 設計上の約束(`TextGeneration` と同じ流儀):
// - 接続は AIテキスト生成の設定(`TextGenerationSettings`)を共有する。未設定の
// ときは `TextGenerationError.notConfigured` で機能が無効になる。
// - 送るのは、対象クリップの文字起こしと指示文だけ。プロジェクト全体や
// 認証情報は送らない。
// - AI の返事は必ず検証(`RoughCutValidation`)を通す。検証を通らない区間は
// 落とし、落とした件数はプランに残して画面で報告する。
// - 組み立て(`RoughCutBuilder`)は元のタイムラインを一切変えず、新しい
// シーン定義を返すだけ。プロジェクトへの反映と Undo は画面側の責務。

/// AI へ渡す素材クリップ 1 件。時刻はすべて素材の頭からの秒(文字起こしの時刻系)。
public struct RoughCutSourceClip: Equatable, Sendable {
    /// タイムライン上のクリップの ID(プランの `clip` はこれを指す)。
    public var clipId: String
    /// 表示名(素材ファイル名など)。
    public var label: String
    /// 元のタイムラインでのレイヤー番号(シーン組み立てでレイヤー構成を保つ)。
    public var trackIndex: Int
    /// このクリップが使っている素材範囲の頭(素材時刻)。
    public var windowStart: Double
    /// このクリップが使っている素材範囲の終わり(素材時刻)。
    public var windowEnd: Double
    /// 窓と重なる文字起こしの文(素材時刻、開始順)。
    public var segments: [TranscriptSegment]
    public init(clipId: String, label: String, trackIndex: Int, windowStart: Double, windowEnd: Double, segments: [TranscriptSegment]) {
        self.clipId = clipId; self.label = label; self.trackIndex = trackIndex
        self.windowStart = windowStart; self.windowEnd = windowEnd; self.segments = segments
    }
    public var windowDuration: Double { max(0, windowEnd - windowStart) }
}

/// ラフカットの依頼。指示は自由文、目標尺は任意。
public struct RoughCutRequest: Equatable, Sendable {
    public var instruction: String
    public var targetDuration: Double?
    public var clips: [RoughCutSourceClip]
    public init(instruction: String, targetDuration: Double? = nil, clips: [RoughCutSourceClip]) {
        self.instruction = instruction; self.targetDuration = targetDuration; self.clips = clips
    }
}

/// 保持区間 1 件(素材時刻)。並びがそのまま再生順。
public struct RoughCutSegment: Equatable, Sendable {
    public var clipId: String
    public var start: Double
    public var end: Double
    /// チャプター名の案(任意。第 1 版では画面の確認用で、プロジェクトには入れない)。
    public var title: String?
    public init(clipId: String, start: Double, end: Double, title: String? = nil) {
        self.clipId = clipId; self.start = start; self.end = end; self.title = title
    }
    public var duration: Double { end - start }
}

/// 検証済みのラフカットプラン。
public struct RoughCutPlan: Equatable, Sendable {
    public var segments: [RoughCutSegment]
    public var summary: String?
    /// 検証で落とした区間の件数(範囲外・短すぎ・重なり・不明なクリップ)。
    public var droppedCount: Int
    public init(segments: [RoughCutSegment], summary: String? = nil, droppedCount: Int = 0) {
        self.segments = segments; self.summary = summary; self.droppedCount = droppedCount
    }
    public var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }
}

/// ラフカット固有の失敗(通信の失敗は `TextGenerationError` が担う)。文は画面に出す日本語。
public enum RoughCutError: Error, LocalizedError, Equatable {
    /// 対象クリップが無い。
    case noSources
    /// 返事からプランを読み取れなかった。
    case unparsable
    /// 読み取れたが、検証を通る区間が 1 つも無かった(括弧内は落とした件数)。
    case emptyPlan(dropped: Int)

    public var errorDescription: String? {
        switch self {
        case .noSources:
            return "文字起こしのある素材クリップがタイムラインにありません。先に素材の文字起こしを作ってください。"
        case .unparsable:
            return "生成サービスの返事からラフカットのプランを読み取れませんでした。モデルやエンドポイントを見直すか、指示を変えてもう一度試してください。"
        case .emptyPlan(let dropped):
            return "AI のプランに、使える区間がありませんでした(検証で \(dropped) 件を落としました)。指示を変えてもう一度試してください。"
        }
    }
}

// MARK: - 対象クリップの収集(純粋関数)

public enum RoughCutSources {
    /// ラフカットの対象にできるクリップか。素材を持ち、タイムライン時刻と素材時刻が
    /// 1 対 1 のものだけ(文字起こしの時刻をそのまま使えるため)。第 1 版は映像・音声のみ。
    public static func isEligible(_ clip: Clip) -> Bool {
        (clip.type == .video || clip.type == .audio) && TranscriptionSupport.supports(clip)
    }

    /// クリップと、その素材の文字起こし(素材時刻)から AI へ渡す 1 件を作る。
    /// 窓と重なる文が無ければ nil。
    public static func sourceClip(clip: Clip, trackIndex: Int, transcript: [TranscriptSegment]) -> RoughCutSourceClip? {
        let start = clip.offset
        let end = clip.offset + ClipTiming.sourceSpan(clip)
        guard end > start else { return nil }
        let segs = transcript
            .filter { $0.end > start && $0.start < end && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !segs.isEmpty else { return nil }
        let label = clip.src.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "クリップ"
        return RoughCutSourceClip(clipId: clip.id, label: label, trackIndex: trackIndex,
                                  windowStart: start, windowEnd: end, segments: segs)
    }

    /// プロジェクト全体から対象を集める。`transcripts` はクリップ → 素材時刻の文字起こし
    /// (保存庫から引くのは画面側の責務。ここは純粋関数に保つ)。
    public static func collect(project: Project, transcripts: (Clip) -> [TranscriptSegment]?) -> [RoughCutSourceClip] {
        var out: [RoughCutSourceClip] = []
        for (ti, track) in project.tracks.enumerated() {
            for clip in track.clips where isEligible(clip) {
                guard let t = transcripts(clip), let s = sourceClip(clip: clip, trackIndex: ti, transcript: t) else { continue }
                out.append(s)
            }
        }
        return out
    }
}

// MARK: - プロンプトの組み立てと返事の読み取り(純粋関数)

public enum RoughCutPrompt {
    /// 送る文字起こしの上限(文字数)。超えた分は末尾から送らない(`truncated` で分かる)。
    public static let maxInputCharacters = 12_000
    /// プランの区間の上限件数。
    public static let maxSegments = 200

    private static func sec(_ v: Double) -> String { String(format: "%.1f", v) }

    /// 依頼からプロンプトを作る。文字起こしが長いときは末尾を切る。
    public static func build(_ r: RoughCutRequest) -> (prompt: String, truncated: Bool) {
        var body = ""
        var truncated = false
        for c in r.clips {
            let header = "[clip: \(c.clipId)] \(c.label)(使える範囲: \(sec(c.windowStart))〜\(sec(c.windowEnd)) 秒)\n"
            if body.count + header.count > maxInputCharacters { truncated = true; break }
            body += header
            for s in c.segments {
                let line = "[\(sec(s.start))-\(sec(s.end))] \(s.text.replacingOccurrences(of: "\n", with: " "))\n"
                if body.count + line.count > maxInputCharacters { truncated = true; break }
                body += line
            }
            if truncated { break }
        }
        let target = r.targetDuration.map { "約 \(sec($0)) 秒" } ?? "(指定なし)"
        let instruction = r.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        あなたは動画編集者です。素材の文字起こしを読んで、ラフカット(粗編集)の構成を作ってください。

        ユーザーの指示: \(instruction.isEmpty ? "(なし)" : instruction)
        目標の尺: \(target)

        書式のルール(厳守):
        - 返事は JSON だけを出力する。説明文・見出し・コードブロックは書かない。
        - 形式: {"summary": "全体の要約(任意)", "segments": [{"clip": "クリップID", "start": 12.3, "end": 15.8, "title": "区間の名前(任意)"}, ...]}
        - segments は再生する順番に並べる。start と end は素材の時刻(秒)で、そのクリップの「使える範囲」の中に収める。
        - 1 つの区間は \(sec(RoughCutValidation.minSegmentLength)) 秒以上にする。同じクリップの中で区間同士を重ねない。
        - 目標の尺があれば、区間の合計が近くなるように選ぶ。つかみになる面白い部分は早めに置く。

        素材:
        \(body)
        """
        return (prompt, truncated)
    }

    /// 返事(JSON)からプランの素材を取り出す。壊れた区間は読み飛ばし、1 件も読めなければ
    /// `RoughCutError.unparsable`。検証(範囲・重なり)は `RoughCutValidation` の担当。
    public static func parse(_ response: String) throws -> (segments: [RoughCutSegment], summary: String?) {
        let text = AIText.stripFences(response)
        guard let lo = text.firstIndex(of: "{"), let hi = text.lastIndex(of: "}"), lo <= hi,
              let data = String(text[lo...hi]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSegments = obj["segments"] as? [[String: Any]] else {
            throw RoughCutError.unparsable
        }
        var out: [RoughCutSegment] = []
        for raw in rawSegments {
            guard let clipId = (raw["clip"] as? String)?.trimmingCharacters(in: .whitespaces), !clipId.isEmpty,
                  let start = number(raw["start"]), let end = number(raw["end"]),
                  start.isFinite, end.isFinite else { continue }
            let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(RoughCutSegment(clipId: clipId, start: start, end: end, title: (title?.isEmpty == false) ? title : nil))
            if out.count >= maxSegments { break }
        }
        guard !out.isEmpty else { throw RoughCutError.unparsable }
        let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (out, (summary?.isEmpty == false) ? summary : nil)
    }

    /// JSON の数値(数値そのもの、または数値文字列)を Double にする。
    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

// MARK: - 検証(純粋関数)

public enum RoughCutValidation {
    /// 区間の最小の長さ(秒)。
    public static let minSegmentLength = 0.5

    /// プランの区間を、素材の範囲・最小長・同一クリップ内の重なりで検証する。
    /// 範囲からはみ出す区間は範囲内に丸めてから判定する。返り値は (残った区間, 落とした件数)。
    /// 並び順はプランのまま(先に来た区間を優先し、重なる後の区間を落とす)。
    public static func validate(_ segments: [RoughCutSegment], clips: [RoughCutSourceClip]) -> (kept: [RoughCutSegment], dropped: Int) {
        let byId = Dictionary(uniqueKeysWithValues: clips.map { ($0.clipId, $0) })
        var kept: [RoughCutSegment] = []
        var keptByClip: [String: [RoughCutSegment]] = [:]
        var dropped = 0
        for s in segments {
            guard let clip = byId[s.clipId], s.start.isFinite, s.end.isFinite else { dropped += 1; continue }
            let start = max(s.start, clip.windowStart)
            let end = min(s.end, clip.windowEnd)
            guard end - start >= minSegmentLength else { dropped += 1; continue }
            let fixed = RoughCutSegment(clipId: s.clipId, start: start, end: end, title: s.title)
            if (keptByClip[s.clipId] ?? []).contains(where: { fixed.start < $0.end && $0.start < fixed.end }) {
                dropped += 1; continue
            }
            kept.append(fixed)
            keptByClip[s.clipId, default: []].append(fixed)
        }
        return (kept, dropped)
    }
}

// MARK: - 組み立て(純粋関数)

public enum RoughCutBuilder {
    /// プランから新しいシーン定義を作る。プロジェクトは変えない。
    /// レイヤー構成は元のタイムラインを写し、プランの順に各レイヤーへ詰めて並べる。
    /// クリップは複製(新しい ID)で、キーフレーム・トランジション・速度ランプは
    /// 元の全体尺に紐づくため持ち越さない(第 1 版の割り切り)。
    public static func makeScene(plan: RoughCutPlan, in project: Project, name: String) -> SceneDefinition? {
        guard !plan.segments.isEmpty else { return nil }
        var byId: [String: (track: Int, clip: Clip)] = [:]
        for (ti, track) in project.tracks.enumerated() {
            for c in track.clips where byId[c.id] == nil { byId[c.id] = (ti, c) }
        }
        let usedTracks = Set(plan.segments.compactMap { byId[$0.clipId]?.track }).sorted()
        guard !usedTracks.isEmpty else { return nil }
        var sceneTracks: [Track] = usedTracks.map { Track(name: project.tracks[$0].name) }
        let position = Dictionary(uniqueKeysWithValues: usedTracks.enumerated().map { ($0.element, $0.offset) })
        var cursors: [Int: Double] = [:]
        for seg in plan.segments {
            guard let src = byId[seg.clipId], let pos = position[src.track] else { continue }
            var c = src.clip
            c.id = newId()
            c.start = cursors[src.track] ?? 0
            c.offset = seg.start
            c.duration = seg.end - seg.start
            c.keyframes = [:]
            c.transitionIn = nil
            c.transitionOut = nil
            c.speedRamp = nil
            sceneTracks[pos].clips.append(c)
            cursors[src.track] = c.start + c.duration
        }
        guard sceneTracks.contains(where: { !$0.clips.isEmpty }) else { return nil }
        return SceneDefinition(id: newId(), name: name, tracks: sceneTracks)
    }
}

// MARK: - プロバイダ境界(差し替え可能)

/// ラフカット生成の差し替え口。
public protocol RoughCutProvider: Sendable {
    func generateRoughCut(_ request: RoughCutRequest) async throws -> RoughCutPlan
}

/// 応答テキストから検証済みプランを作る(実プロバイダと偽物の共通処理)。
public enum RoughCutPlanning {
    public static func plan(fromResponse text: String, clips: [RoughCutSourceClip]) throws -> RoughCutPlan {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextGenerationError.emptyResponse }
        let parsed = try RoughCutPrompt.parse(text)
        let v = RoughCutValidation.validate(parsed.segments, clips: clips)
        guard !v.kept.isEmpty else { throw RoughCutError.emptyPlan(dropped: v.dropped) }
        return RoughCutPlan(segments: v.kept, summary: parsed.summary, droppedCount: v.dropped)
    }
}

/// ユーザーが設定したエンドポイントへ送る汎用クライアント(OpenAI 互換 chat completions 形式)。
/// 通信は `TextGenerationTransport` 境界の後ろにあり、テストでは差し替えられる。
public struct OpenAICompatibleRoughCutProvider: RoughCutProvider {
    public let endpoint: URL
    public let model: String
    private let apiKey: String
    public let timeout: TimeInterval
    public let transport: TextGenerationTransport

    public init(endpoint: URL, model: String, apiKey: String = "", timeout: TimeInterval = 120,
                transport: TextGenerationTransport = URLSessionTextTransport()) {
        self.endpoint = endpoint; self.model = model; self.apiKey = apiKey
        self.timeout = timeout; self.transport = transport
    }

    /// 送る URLRequest(テストで中身を確認できるよう公開)。キーはヘッダーにだけ入る。
    public func makeRequest(_ request: RoughCutRequest) throws -> URLRequest {
        let prompt = RoughCutPrompt.build(request).prompt
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.4,
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public func generateRoughCut(_ request: RoughCutRequest) async throws -> RoughCutPlan {
        guard !request.clips.isEmpty else { throw RoughCutError.noSources }
        let urlRequest = try makeRequest(request)
        let (data, status) = try await transport.send(urlRequest)
        guard (200..<300).contains(status) else {
            throw TextGenerationError.http(status, String(decoding: data, as: UTF8.self))
        }
        let text = try OpenAICompatibleTextProvider.responseText(from: data)
        return try RoughCutPlanning.plan(fromResponse: text, clips: request.clips)
    }
}

extension TextGenerationSettings {
    /// AIテキスト生成の設定からラフカット用のプロバイダを作る。未設定・不正なら日本語のエラー。
    public func makeRoughCutProvider(transport: TextGenerationTransport = URLSessionTextTransport()) throws -> RoughCutProvider {
        if let problem = Self.endpointProblem(endpoint) {
            if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw TextGenerationError.notConfigured }
            throw TextGenerationError.invalidEndpoint(problem)
        }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw TextGenerationError.notConfigured }
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TextGenerationError.invalidEndpoint("URL の形になっていません")
        }
        return OpenAICompatibleRoughCutProvider(endpoint: url, model: model.trimmingCharacters(in: .whitespaces),
                                                apiKey: apiKey, timeout: TimeInterval(timeoutSeconds), transport: transport)
    }
}

// MARK: - テスト用モック

/// 決まったプランを返す(または失敗させる)偽のプロバイダ。実サービスとの疎通なしに
/// 生成 → 確認 → 適用の流れを通しで確認するために使う。
public final class FakeRoughCutProvider: RoughCutProvider, @unchecked Sendable {
    public enum Behavior: Sendable {
        case plan(RoughCutPlan)
        /// 生の応答文(パースと検証を通す)。
        case raw(String)
        case fail(TextGenerationError)
        case failRoughCut(RoughCutError)
    }
    private let lock = NSLock()
    private var _requests: [RoughCutRequest] = []
    public let behavior: Behavior
    public init(_ b: Behavior) { behavior = b }
    public var requests: [RoughCutRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    public func generateRoughCut(_ request: RoughCutRequest) async throws -> RoughCutPlan {
        lock.withLock { _requests.append(request) }
        switch behavior {
        case .plan(let p): return p
        case .raw(let text): return try RoughCutPlanning.plan(fromResponse: text, clips: request.clips)
        case .fail(let e): throw e
        case .failRoughCut(let e): throw e
        }
    }
}
