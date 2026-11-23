import Foundation

// MARK: - AIテキスト生成(W3-08 / YMM4監査 #74)
//
// 台本欄・台本編集ウィンドウから、テーマやキーワードを与えてセリフ案を生成し、
// 選んで台本へ取り込むための土台。画面にも Undo にも依存しない純粋な処理と、
// 差し替え可能なプロバイダ境界(`TextGenerationProvider`)を持つ。
//
// 設計上の約束(従来の AI 連携と同じ流儀):
// - 認証情報(APIキー等)はコード・プロジェクトファイル・テストに含めない。
// 接続情報はユーザー自身がアプリの設定で入れる(`TextGenerationSettings`。
// 保存先はこの Mac のアプリ設定(UserDefaults)だけで、プロジェクトには書かない)。
// - 未設定のときは機能が無効になる。`TextGenerationSettings.makeProvider()` は
// `TextGenerationError.notConfigured` を投げ、画面側はその旨を表示する。
// - 既存の内蔵 AI(コマンド版 `AIProvider`)とは独立した追加で、使わない場合の
// 従来挙動には一切影響しない。
//
// 初期実装のプロバイダ:
// - `OpenAICompatibleTextProvider`: ユーザーが設定したエンドポイントへ
// OpenAI 互換の chat completions 形式で送る汎用クライアント。
// 通信は `TextGenerationTransport` 境界の後ろにあり、テストでは差し替えられる。
// - `FakeTextGenerationProvider`: テスト用モック(決まった案を返す/失敗する)。

/// セリフ案 1 件。`characterName` は台本の「名前: セリフ」の名前(無ければ nil = 話者なしの文)。
public struct DialogueSuggestion: Equatable, Sendable {
public var characterName: String?
public var text: String
public init(characterName: String?, text: String) {
self.characterName = characterName
self.text = text
}
/// 台本欄へ入れる 1 行(「名前: セリフ」。名前が無ければセリフだけ)。
public var scriptLine: String {
let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
guard let name = characterName?.trimmingCharacters(in: .whitespaces) , !name.isEmpty else { return body}
return "\(name): \(body)"
}
}

/// 生成の依頼。テーマ必須、キーワードは任意。`contextLines` は今の台本の行(続きを作るための参考)。
public struct DialogueGenerationRequest: Equatable, Sendable {
public var theme: String
public var keywords: [String]
public var characterNames: [String]
public var count: Int
public var contextLines: [String]
public init(theme: String, keywords: [String] = [], characterNames: [String], count: Int = 8, contextLines: [String] = []) {
self.theme = theme
self.keywords = keywords
self.characterNames = characterNames
self.count = count
self.contextLines = contextLines
}
}

/// AIテキスト生成の失敗。`errorDescription` は画面に出す日本語。
public enum TextGenerationError: Error, LocalizedError, Equatable {
/// エンドポイント等が未設定(機能は無効)。
case notConfigured
/// エンドポイントの URL が不正、または安全でない(http の非ローカル宛先など)。
case invalidEndpoint(String)
/// HTTP のエラー応答(状態コードと本文の冒頭)。
case http(Int, String)
/// 返事が空だった。
case emptyResponse
/// 返事からセリフ案を読み取れなかった。
case unparsable
/// 通信そのものの失敗(詳細は画面用の文)。
case transport(String)
/// キャンセルされた。
case cancelled

public var errorDescription: String? {
switch self {
case .notConfigured:
return "AIテキスト生成が設定されていません。ファイル ▸ AIテキスト生成の設定… で、接続先のエンドポイントとモデルを指定してください(未設定のあいだは、この機能は使えません)。"
case .invalidEndpoint(let why):
return "エンドポイントが正しくありません: \(why)"
case .http(let code, let body):
let tail = body.trimmingCharacters(in: .whitespacesAndNewlines)
return "生成サービスがエラーを返しました(HTTP \(code))。" + (tail.isEmpty ? "": "\n" + String(tail.prefix(300)))
case .emptyResponse:
return "生成サービスの返事が空でした。"
case .unparsable:
return "生成サービスの返事からセリフ案を読み取れませんでした。モデルやエンドポイントを見直してください。"
case .transport(let detail):
return "生成サービスへつながりませんでした: \(detail)"
case .cancelled:
return "キャンセルしました。"
}
}
}

// MARK: - プロンプトの組み立てと返事の読み取り(純粋関数)

public enum DialogueSuggestionPrompt {
public static let countRange = 1...30
public static let maxSuggestions = 60
public static let maxContextLines = 20
public static let maxContextCharacters = 3000

public static func build(_ r: DialogueGenerationRequest) -> String {
let n = min(max(r.count, countRange.lowerBound), countRange.upperBound)
let names = r.characterNames.joined(separator: "、")
let keywords = r.keywords.map { $0.trimmingCharacters(in: .whitespaces)}.filter { !$0.isEmpty}
var context = ""
if !r.contextLines.isEmpty {
var body = ""
for line in r.contextLines.suffix(maxContextLines) {
let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
guard !l.isEmpty else { continue}
if body.count + l.count + 1 > maxContextCharacters { break}
body += l + "\n"
}
if !body.isEmpty {
context = "\n\n今の台本(この続き・流れに合う案にしてください):\n\(body)"
}
}
return """
あなたは動画の台本を書く作家です。次の条件で、セリフの案を作ってください。

テーマ: \(r.theme.trimmingCharacters(in: .whitespacesAndNewlines))
キーワード: \(keywords.isEmpty ? "(なし)": keywords.joined(separator: "、"))
登場キャラ: \(names)
件数: \(n) 件

書式のルール(厳守):
- 1 行に 1 つのセリフ案。形式は「キャラ名: セリフ」(キャラ名は上の登場キャラの名前だけを使う)。
- 見出し、説明、番号、記号、コードブロックは書かない。セリフの行だけを出力する。
- 1 つのセリフは短めに(目安 40 文字以内)。声に出して読める文にする。\(context)
"""
}

/// 返事をセリフ案の列にする。コードブロックや箇条書き記号は外す。
/// 「名前: セリフ」で名前が既知のキャラなら話者つき、区切りの無い行は話者なしの案として拾う。
/// 知らない名前の行(説明文など)は捨てる。重複は除き、1 件も無ければ `unparsable`。
public static func parse(_ response: String, characterNames: [String]) throws -> [DialogueSuggestion] {
var out: [DialogueSuggestion] = []
var seen: Set<String> = []
var hasNamed = false
for raw in AIText.stripFences(response).components(separatedBy: .newlines) {
let l = AIText.cleanLine(raw)
guard !l.isEmpty else { continue}
let suggestion: DialogueSuggestion
if let sep = l.firstIndex(where: { $0 == ":" || $0 == "："}), sep !=  l.startIndex {
var name = l[l.startIndex..<sep].trimmingCharacters(in: .whitespaces)
for q in ["「", "」", "[", "]", "", "(", ")"] { name = name.replacingOccurrences(of: q, with: "")}
var rest = l[l.index(after: sep)...].trimmingCharacters(in: .whitespaces)
if rest.hasPrefix("「"), rest.hasSuffix("」"), rest.count >= 2 { rest = String(rest.dropFirst().dropLast())}
guard !rest.isEmpty else { continue}
if characterNames.contains(name) {
suggestion = DialogueSuggestion(characterName: name, text: rest)
hasNamed = true
} else if characterNames.isEmpty {
suggestion = DialogueSuggestion(characterName: nil, text: rest)
} else {
continue // 知らない名前 = 説明文として捨てる
}
} else {
suggestion = DialogueSuggestion(characterName: nil, text: l)
}
guard seen.insert(suggestion.scriptLine).inserted else { continue}
out.append(suggestion)
if out.count >= maxSuggestions { break}
}
guard !out.isEmpty else { throw TextGenerationError.unparsable}
// キャラが指定されているのに名前つきの行が 1 つも無い応答は、謝罪文などの説明文とみなして弾く
guard characterNames.isEmpty || hasNamed else { throw TextGenerationError.unparsable }
return out
}
}

// MARK: - プロバイダ境界(差し替え可能)

/// テキスト生成の差し替え口。プラグイン機構と同じ流儀で、実装を差し替えられる。
public protocol TextGenerationProvider: Sendable {
func generateDialogue(_ request: DialogueGenerationRequest) async throws -> [DialogueSuggestion]
}

/// HTTP 通信の差し替え口(テストでは実通信をせずに済む)。
public protocol TextGenerationTransport: Sendable {
/// 応答の本文と HTTP 状態コードを返す。通信失敗は throw。
func send(_ request: URLRequest) async throws -> (Data, Int)
}

/// URLSession による実通信。
public struct URLSessionTextTransport: TextGenerationTransport {
public init() {}
public func send(_ request: URLRequest) async throws -> (Data, Int) {
do {
let (data, response) = try await URLSession.shared.data(for: request)
guard let http = response as? HTTPURLResponse else { throw TextGenerationError.transport("HTTP の応答ではありませんでした")}
return (data, http.statusCode)
} catch let e as TextGenerationError {
throw e
} catch is CancellationError {
throw TextGenerationError.cancelled
} catch {
throw TextGenerationError.transport(error.localizedDescription)
}
}
}

/// ユーザーが設定したエンドポイントへ送る汎用クライアント(OpenAI 互換 chat completions 形式)。
/// 送り先の URL は設定そのまま(例: `https://…/v1/chat/completions`、`http://127.0.0.1:11434/v1/chat/completions`)。
/// APIキーは設定にあるときだけ Authorization ヘッダーに使う。コードにもログにもキーは出さない。
public struct OpenAICompatibleTextProvider: TextGenerationProvider {
public let endpoint: URL
public let model: String
private let apiKey: String
public let timeout: TimeInterval
public let transport: TextGenerationTransport

public init(endpoint: URL, model: String, apiKey: String = "", timeout: TimeInterval = 120,
transport: TextGenerationTransport = URLSessionTextTransport()) {
self.endpoint = endpoint
self.model = model
self.apiKey = apiKey
self.timeout = timeout
self.transport = transport
}

/// 送る URLRequest(テストで中身を確認できるよう公開)。キーはヘッダーにだけ入る。
public func makeRequest(_ dialogueRequest: DialogueGenerationRequest) throws -> URLRequest {
let prompt = DialogueSuggestionPrompt.build(dialogueRequest)
let body: [String: Any] = [
"model": model,
"messages": [["role": "user", "content": prompt]],
"temperature": 0.7,
]
var req = URLRequest(url: endpoint)
req.httpMethod = "POST"
req.timeoutInterval = timeout
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")}
req.httpBody = try JSONSerialization.data(withJSONObject: body)
return req
}

/// 応答 JSON から本文を取り出す(chat completions の `choices[0].message.content`、
/// 無ければ completions 形式の `choices[0].text`)。純粋関数。
public static func responseText(from data: Data) throws -> String {
guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
let choices = obj["choices"] as? [[String: Any]], let first = choices.first else {
throw TextGenerationError.unparsable
}
if let message = first["message"] as? [String: Any], let content = message["content"] as? String {
return content
}
if let text = first["text"] as? String { return text}
throw TextGenerationError.unparsable
}

public func generateDialogue(_ request: DialogueGenerationRequest) async throws -> [DialogueSuggestion] {
let urlRequest = try makeRequest(request)
let (data, status) = try await transport.send(urlRequest)
guard (200..<300).contains(status) else {
throw TextGenerationError.http(status, String(decoding: data, as: UTF8.self))
}
let text = try Self.responseText(from: data)
guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextGenerationError.emptyResponse}
return try DialogueSuggestionPrompt.parse(text, characterNames: request.characterNames)
}
}

// MARK: - 設定(ユーザーがアプリ設定で入れる。プロジェクトには書かない)

public struct TextGenerationSettings: Equatable, Sendable {
/// 接続先の完全な URL(例: `https://api.example.com/v1/chat/completions`)。
public var endpoint: String = ""
/// モデル名(例: `gpt-…`、`llama…`。サービス側の名前をそのまま)。
public var model: String = ""
/// APIキー。ユーザー自身が設定画面で入れたものだけが入る。この Mac のアプリ設定にだけ保存し、
/// プロジェクトファイル・ログ・送信前の確認文には出さない。ローカルなサービスでは空でよい。
public var apiKey: String = ""
public var timeoutSeconds: Int = 120

public static let timeoutRange = 5...900
static let endpointKey = "textgen.endpoint", modelKey = "textgen.model", apiKeyKey = "textgen.apiKey", timeoutKey = "textgen.timeout"

public init() {}

public static func load(from d: UserDefaults = DataLocations.current.defaults, secrets: SecretStore = .shared) -> TextGenerationSettings {
var s = TextGenerationSettings()
s.endpoint = d.string(forKey: endpointKey) ??  ""
s.model = d.string(forKey: modelKey) ??  ""
s.apiKey = secrets.load(account: apiKeyKey, migratingFrom: d)
let t = d.integer(forKey: timeoutKey)
s.timeoutSeconds = t == 0 ? 120: min(max(t, timeoutRange.lowerBound), timeoutRange.upperBound)
return s
}

public func save(to d: UserDefaults = DataLocations.current.defaults, secrets: SecretStore = .shared) {
d.set(endpoint, forKey: Self.endpointKey)
d.set(model, forKey: Self.modelKey)
secrets.set(apiKey, account: Self.apiKeyKey)
d.removeObject(forKey: Self.apiKeyKey)
d.set(timeoutSeconds, forKey: Self.timeoutKey)
}

/// エンドポイントが使える形か(検証結果)。https は可。http はこの Mac 自身(localhost)宛てだけ可
/// (平文でキーや台本を外へ送らないため)。
public static func endpointProblem(_ raw: String) -> String? {
let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmed.isEmpty else { return "エンドポイントが空です"}
guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host , !host.isEmpty else {
return "URL の形になっていません"
}
switch scheme {
case "https": return nil
case "http":
let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
return localHosts.contains(host.lowercased()) ? nil: "http で送れるのはこの Mac 自身(localhost)宛てだけです。外のサービスには https を使ってください"
default:
return "https(または localhost 宛ての http)の URL を指定してください"
}
}

/// 設定がそろっていて機能が有効か。未設定・不正なら false で、画面はその旨を出す。
public var isConfigured: Bool {
!model.trimmingCharacters(in: .whitespaces).isEmpty && Self.endpointProblem(endpoint) == nil
}

/// 設定からプロバイダを作る。未設定・不正なら日本語のエラー。
public func makeProvider(transport: TextGenerationTransport = URLSessionTextTransport()) throws -> TextGenerationProvider {
if let problem = Self.endpointProblem(endpoint) {
if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw TextGenerationError.notConfigured}
throw TextGenerationError.invalidEndpoint(problem)
}
guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw TextGenerationError.notConfigured}
guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
throw TextGenerationError.invalidEndpoint("URL の形になっていません")
}
return OpenAICompatibleTextProvider(endpoint: url, model: model.trimmingCharacters(in: .whitespaces),
apiKey: apiKey, timeout: TimeInterval(timeoutSeconds), transport: transport)
}

/// 送信先の説明(画面に出す。キーは含めない)。
public var destinationDescription: String {
guard isConfigured else { return "(未設定)"}
return "\(endpoint) / モデル: \(model)"
}
}

// MARK: - テスト用モック

/// 決まったセリフ案を返す(または失敗させる)偽のプロバイダ。実サービスとの疎通なしに
/// 生成 → 選択 → 取り込みの流れを通しで確認するために使う。
public final class FakeTextGenerationProvider: TextGenerationProvider, @unchecked Sendable {
public enum Behavior: Sendable {
case suggestions([DialogueSuggestion])
case fail(TextGenerationError)
case delay(seconds: Double, suggestions: [DialogueSuggestion])
}
private let lock = NSLock()
private var _requests: [DialogueGenerationRequest] = []
public let behavior: Behavior
public init(_ b: Behavior) { behavior = b}
public var requests: [DialogueGenerationRequest] { lock.lock(); defer { lock.unlock()}; return _requests}

public func generateDialogue(_ request: DialogueGenerationRequest) async throws -> [DialogueSuggestion] {
lock.withLock { _requests.append(request)}
switch behavior {
case .suggestions(let s): return s
case .fail(let e): throw e
case .delay(let sec, let s):
do { try await Task.sleep(nanoseconds: UInt64((sec.isFinite ? max(0, min(sec, 3600)) : 0) * 1_000_000_000))} catch { throw TextGenerationError.cancelled}
return s
}
}
}

// MARK: - 台本への取り込み(純粋関数)

public enum DialogueImport {
/// セリフ案を台本の行にする(空の案は捨てる)。
public static func lines(from suggestions: [DialogueSuggestion]) -> [String] {
suggestions.map(\.scriptLine).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty}
}

/// 台本テキストの末尾へ行を足す。既にある行と重なるものは足さない。
/// 返り値は (足したあとの全文, 足した行数)。Undo の登録は呼び出し側(画面側)の責務。
public static func appending(_ suggestions: [DialogueSuggestion], to script: String) -> (text: String, added: Int) {
let existing = Set(script.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces)})
let fresh = lines(from: suggestions).filter { !existing.contains($0.trimmingCharacters(in: .whitespaces))}
guard !fresh.isEmpty else { return (script, 0)}
let add = fresh.joined(separator: "\n")
let base = script.trimmingCharacters(in: .whitespacesAndNewlines)
return (base.isEmpty ? add: script.trimmingCharacters(in: .newlines) + "\n" + add, fresh.count)
}
}
