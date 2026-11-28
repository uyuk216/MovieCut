import XCTest
import Foundation
@testable import MovieCutCore

/// user_dict 用の偽エンジン(呼び出しを記録し、GET /user_dict には設定した辞書を返す)。
final class UserDictFake: URLProtocol {
    struct Call { var method: String; var path: String; var query: [String: String] }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var dictJSON = "{}"
    nonisolated(unsafe) static var failWithStatus: Int?
    nonisolated(unsafe) static var refuseConnection = false
    static let lock = NSLock()

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [UserDictFake.self]
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.refuseConnection { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let u = request.url!
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        var q: [String: String] = [:]
        for i in comps.queryItems ?? [] { q[i.name] = i.value ?? "" }
        Self.lock.withLock { Self.calls.append(Call(method: request.httpMethod ?? "GET", path: comps.path, query: q)) }
        var status = 200
        var data = Data()
        if let f = Self.failWithStatus, request.httpMethod != "GET" { status = f }
        else if comps.path == "/user_dict" { data = Data(Self.dictJSON.utf8) }
        else if request.httpMethod == "POST" { data = Data("\"new-uuid\"".utf8) }
        else { status = 204 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: u, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class VoicevoxUserDictTests: XCTestCase {
    static let policy = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["fake.local"])
    func client() -> VoicevoxClient {
        VoicevoxClient(baseURL: "http://fake.local:50021", cache: VoiceCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ud-\(UUID().uuidString)")), session: UserDictFake.session(), policy: Self.policy)
    }
    override func setUp() {
        UserDictFake.calls = []; UserDictFake.failWithStatus = nil; UserDictFake.refuseConnection = false
        UserDictFake.dictJSON = "{}"
    }

    // MARK: エントリの保存形式
    func testEntryRoundTripWithExtendedFields() throws {
        let e = ReadingEntry(word: "相棒", reading: "あいぼう", accentType: 2, partOfSpeech: .commonNoun, priority: 7)
        let back = try JSONDecoder().decode(ReadingEntry.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
    }
    func testOldFormatLoadsAndStaysOld() throws {
        let old = Data(#"{"word":"相棒","reading":"あいぼう"}"#.utf8)
        let e = try JSONDecoder().decode(ReadingEntry.self, from: old)
        XCTAssertEqual(e, ReadingEntry(word: "相棒", reading: "あいぼう"))
        XCTAssertNil(e.accentType); XCTAssertNil(e.partOfSpeech); XCTAssertNil(e.priority)
        let out = String(data: try JSONEncoder().encode(e), encoding: .utf8)!
        XCTAssertFalse(out.contains("accentType")); XCTAssertFalse(out.contains("priority"))
    }
    func testProjectRoundTripKeepsExtendedEntry() throws {
        var p = Project.new()
        p.readingDictionary = [ReadingEntry(word: "本音", reading: "ほんね", accentType: 1, partOfSpeech: .properNoun, priority: 9)]
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.readingDictionary, p.readingDictionary)
    }

    // MARK: 純粋関数
    func testKatakana() {
        XCTAssertEqual(VoicevoxUserDictSync.katakana("あいぼう"), "アイボウ")
        XCTAssertEqual(VoicevoxUserDictSync.katakana("らーめん"), "ラーメン")
        XCTAssertEqual(VoicevoxUserDictSync.katakana("ABCあ"), "ABCア")
    }
    func testDraftDefaultsAndClamp() {
        let d = VoicevoxUserDictDraft(entry: ReadingEntry(word: "相棒", reading: "あいぼう"))
        XCTAssertEqual(d, VoicevoxUserDictDraft(surface: "相棒", pronunciation: "アイボウ", accentType: 0, wordType: "PROPER_NOUN", priority: 5))
        XCTAssertEqual(VoicevoxUserDictDraft(entry: ReadingEntry(word: "a", reading: "あ", accentType: -3, priority: 99)).priority, 10)
        XCTAssertEqual(VoicevoxUserDictDraft(entry: ReadingEntry(word: "a", reading: "あ", accentType: -3)).accentType, 0)
    }
    func testPlanAddUpdateUnchangedDelete() {
        let engine = [
            VoicevoxUserDictWord(uuid: "u1", surface: "相棒", pronunciation: "アイボウ", accentType: 0, wordType: "PROPER_NOUN", priority: 5), // 同じ
            VoicevoxUserDictWord(uuid: "u2", surface: "本音", pronunciation: "ホンネ", accentType: 0, wordType: "PROPER_NOUN", priority: 5), // 違う
            VoicevoxUserDictWord(uuid: "u3", surface: "余分", pronunciation: "ヨブン", accentType: 0, wordType: "PROPER_NOUN", priority: 5),
            VoicevoxUserDictWord(uuid: "u4", surface: "余分", pronunciation: "ヨブン", accentType: 0, wordType: "PROPER_NOUN", priority: 5)]
        let entries = [ReadingEntry(word: "相棒", reading: "あいぼう"),
                       ReadingEntry(word: "本音", reading: "ほんね", accentType: 2),
                       ReadingEntry(word: "新語", reading: "しんご")]
        let keep = VoicevoxUserDictSync.plan(entries: entries, engine: engine, deleteExtras: false)
        XCTAssertEqual(keep.unchanged, 1)
        XCTAssertEqual(keep.updates.map(\.uuid), ["u2"])
        XCTAssertEqual(keep.updates.first?.draft.accentType, 2)
        XCTAssertEqual(keep.adds.map(\.surface), ["新語"])
        XCTAssertTrue(keep.deletes.isEmpty, "既定ではエンジン側の余分な語は消さない")
        let del = VoicevoxUserDictSync.plan(entries: entries, engine: engine, deleteExtras: true)
        XCTAssertEqual(del.deletes.map(\.uuid), ["u3", "u4"])
    }

    // MARK: クライアント
    func testUserDictGetParses() async throws {
        UserDictFake.dictJSON = #"{"b-uuid":{"surface":"本音","pronunciation":"ホンネ","accent_type":1,"word_type":"COMMON_NOUN","priority":7},"a-uuid":{"surface":"相棒","pronunciation":"アイボウ","accent_type":0,"word_type":"PROPER_NOUN","priority":5}}"#
        let words = try await client().userDict()
        XCTAssertEqual(words.map(\.uuid), ["a-uuid", "b-uuid"])
        XCTAssertEqual(words[1], VoicevoxUserDictWord(uuid: "b-uuid", surface: "本音", pronunciation: "ホンネ", accentType: 1, wordType: "COMMON_NOUN", priority: 7))
        XCTAssertEqual(UserDictFake.calls.first?.method, "GET")
        XCTAssertEqual(UserDictFake.calls.first?.path, "/user_dict")
    }
    func testAddUpdateDeleteRequestShape() async throws {
        let c = client()
        let d = VoicevoxUserDictDraft(surface: "相棒", pronunciation: "アイボウ", accentType: 2, wordType: "COMMON_NOUN", priority: 8)
        let id = try await c.addUserDictWord(d)
        XCTAssertEqual(id, "new-uuid")
        try await c.updateUserDictWord(uuid: "abc-1", d)
        try await c.deleteUserDictWord(uuid: "abc-1")
        let calls = UserDictFake.calls
        XCTAssertEqual(calls.map(\.method), ["POST", "PUT", "DELETE"])
        XCTAssertEqual(calls[0].path, "/user_dict_word")
        XCTAssertEqual(calls[0].query, ["surface": "相棒", "pronunciation": "アイボウ", "accent_type": "2", "word_type": "COMMON_NOUN", "priority": "8"])
        XCTAssertEqual(calls[1].path, "/user_dict_word/abc-1")
        XCTAssertEqual(calls[1].query["accent_type"], "2")
        XCTAssertEqual(calls[2].path, "/user_dict_word/abc-1")
        XCTAssertTrue(calls[2].query.isEmpty)
    }
    func testHTTPErrorIsReported() async {
        UserDictFake.failWithStatus = 422
        do { _ = try await client().addUserDictWord(VoicevoxUserDictDraft(surface: "a", pronunciation: "ア", accentType: 0, wordType: "PROPER_NOUN", priority: 5)); XCTFail() }
        catch let VoiceError.http(_, code) { XCTAssertEqual(code, 422) }
        catch { XCTFail("\(error)") }
    }
    func testEngineDownGivesConnectionError() async {
        UserDictFake.refuseConnection = true
        do { _ = try await client().userDict(); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("接続できません"), error.localizedDescription) }
        do { _ = try await client().syncUserDict(entries: [ReadingEntry(word: "a", reading: "あ")]); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("接続できません")) }
    }
    func testSyncAppliesPlanAndReports() async throws {
        UserDictFake.dictJSON = #"{"u2":{"surface":"本音","pronunciation":"ホンネ","accent_type":0,"word_type":"PROPER_NOUN","priority":5},"u9":{"surface":"余分","pronunciation":"ヨブン","accent_type":0,"word_type":"PROPER_NOUN","priority":5}}"#
        let entries = [ReadingEntry(word: "本音", reading: "ほんね", accentType: 1), ReadingEntry(word: "相棒", reading: "あいぼう")]
        let r = try await client().syncUserDict(entries: entries, deleteExtras: true)
        XCTAssertEqual(r.added, 1); XCTAssertEqual(r.updated, 1); XCTAssertEqual(r.deleted, 1); XCTAssertTrue(r.failures.isEmpty)
        XCTAssertEqual(UserDictFake.calls.map { "\($0.method) \($0.path)" }, ["GET /user_dict", "POST /user_dict_word", "PUT /user_dict_word/u2", "DELETE /user_dict_word/u9"])
    }
    func testSyncCollectsPerWordFailures() async throws {
        UserDictFake.failWithStatus = 500
        let r = try await client().syncUserDict(entries: [ReadingEntry(word: "相棒", reading: "あいぼう")])
        XCTAssertEqual(r.added, 0); XCTAssertEqual(r.failures.count, 1)
        XCTAssertTrue(r.summary.contains("相棒"))
    }

    // MARK: AquesTalk 経路でも読みの置換が効く(合成の直前に全エンジン共通で適用)
    func testDictionaryAppliedBeforeAnyEngine() async throws {
        final class Rec: VoiceProvider, @unchecked Sendable {
            var texts: [String] = []
            func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
                texts.append(text); return VoiceResult(url: directory.appendingPathComponent("x.wav"), duration: 1)
            }
        }
        let rec = Rec()
        var ch = Character(); ch.name = "れいむ"; ch.engine = "aquestalk"
        let p = DictionaryVoiceProvider(inner: rec, entries: [ReadingEntry(word: "相棒", reading: "あいぼう", accentType: 1)])
        _ = try await p.synthesize(character: ch, text: "相棒だよ", in: FileManager.default.temporaryDirectory)
        XCTAssertEqual(rec.texts, ["あいぼうだよ"])
    }
}
