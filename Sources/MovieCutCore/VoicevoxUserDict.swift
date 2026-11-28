import Foundation

// MARK: - VOICEVOX user_dict 連携
//
// アプリ内の読み辞書(`ReadingEntry`)を、VOICEVOX エンジンのユーザー辞書(/user_dict 系 API)へ反映する。
// - 同期は「表記(surface)」をキーにした差分(追加・更新・そのまま・削除)。計画は純粋関数 `VoicevoxUserDictSync.plan`。
// - エンジン側にしかない語(VOICEVOX 本体で登録した語など)は、既定では消さない(`deleteExtras` を明示したときだけ削除)。
// - エンジン未起動などの通信失敗は「接続できない」を示す `VoiceError.message` にして投げる(アプリは落ちない)。

/// エンジン側の辞書 1 語(GET /user_dict の値)。
public struct VoicevoxUserDictWord: Equatable, Sendable {
    public var uuid: String
    public var surface: String
    /// カタカナ読み。
    public var pronunciation: String
    public var accentType: Int
    public var wordType: String
    public var priority: Int

    public init(uuid: String, surface: String, pronunciation: String, accentType: Int, wordType: String, priority: Int) {
        self.uuid = uuid; self.surface = surface; self.pronunciation = pronunciation
        self.accentType = accentType; self.wordType = wordType; self.priority = priority
    }
}

/// エンジンへ送る 1 語(追加・更新の本文)。
public struct VoicevoxUserDictDraft: Equatable, Sendable {
    public var surface: String
    public var pronunciation: String
    public var accentType: Int
    public var wordType: String
    public var priority: Int

    public static let defaultAccentType = 0
    public static let defaultPriority = 5
    public static let defaultWordType = ReadingPartOfSpeech.properNoun.rawValue

    public init(surface: String, pronunciation: String, accentType: Int, wordType: String, priority: Int) {
        self.surface = surface; self.pronunciation = pronunciation
        self.accentType = accentType; self.wordType = wordType; self.priority = priority
    }

    /// アプリの辞書 1 件から作る(読みはカタカナへ。未指定の項目は既定値、優先度は 0〜10 に丸める)。
    public init(entry: ReadingEntry) {
        self.surface = entry.word
        self.pronunciation = VoicevoxUserDictSync.katakana(entry.reading)
        self.accentType = max(0, entry.accentType ?? Self.defaultAccentType)
        self.wordType = (entry.partOfSpeech ?? .properNoun).rawValue
        self.priority = min(10, max(0, entry.priority ?? Self.defaultPriority))
    }
}

public enum VoicevoxUserDictSync {
    /// ひらがな → カタカナ(他の文字、長音「ー」はそのまま)。
    public static func katakana(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { u in
            (0x3041...0x3096).contains(u.value) ? (Unicode.Scalar(u.value + 0x60) ?? u) : u
        }))
    }

    public struct Plan: Equatable, Sendable {
        public var adds: [VoicevoxUserDictDraft] = []
        public var updates: [(uuid: String, draft: VoicevoxUserDictDraft)] = []
        public var deletes: [VoicevoxUserDictWord] = []
        public var unchanged = 0
        public static func == (a: Plan, b: Plan) -> Bool {
            a.adds == b.adds && a.deletes == b.deletes && a.unchanged == b.unchanged
                && a.updates.map(\.uuid) == b.updates.map(\.uuid) && a.updates.map(\.draft) == b.updates.map(\.draft)
        }
    }

    /// アプリの辞書とエンジン側の語から、必要な操作を決める(純粋関数)。
    /// - 表記が同じ語は内容が違えば更新、同じならそのまま。エンジン側に同じ表記が複数あれば最初の 1 語だけを対象にする。
    /// - アプリに無い表記のエンジン側の語は、`deleteExtras` のときだけ削除(同じ表記の 2 語目以降も削除対象)。
    public static func plan(entries: [ReadingEntry], engine: [VoicevoxUserDictWord], deleteExtras: Bool) -> Plan {
        var plan = Plan()
        let drafts = ReadingDictionary.normalized(entries).map(VoicevoxUserDictDraft.init(entry:))
        var firstBySurface: [String: VoicevoxUserDictWord] = [:]
        var duplicates: [VoicevoxUserDictWord] = []
        for w in engine.sorted(by: { $0.uuid < $1.uuid }) {
            if firstBySurface[w.surface] == nil { firstBySurface[w.surface] = w } else { duplicates.append(w) }
        }
        for d in drafts {
            if let w = firstBySurface[d.surface] {
                let same = w.pronunciation == d.pronunciation && w.accentType == d.accentType && w.wordType == d.wordType && w.priority == d.priority
                if same { plan.unchanged += 1 } else { plan.updates.append((w.uuid, d)) }
            } else {
                plan.adds.append(d)
            }
        }
        if deleteExtras {
            let mine = Set(drafts.map(\.surface))
            plan.deletes = (firstBySurface.values.filter { !mine.contains($0.surface) } + duplicates).sorted { $0.uuid < $1.uuid }
        }
        return plan
    }

    /// 反映結果(画面に出す)。
    public struct Report: Equatable, Sendable {
        public var added = 0, updated = 0, deleted = 0, unchanged = 0
        /// 失敗した語と理由(「表記: 理由」)。
        public var failures: [String] = []
        public var summary: String {
            var s = "追加 \(added) 件・更新 \(updated) 件・削除 \(deleted) 件・変更なし \(unchanged) 件"
            if !failures.isEmpty { s += "\n失敗 \(failures.count) 件:\n" + failures.joined(separator: "\n") }
            return s
        }
    }
}

extension VoicevoxClient {
    /// 通信失敗(未起動・接続拒否・タイムアウト)を「接続できない」エラーへ。
    private func userDictSend(_ req: URLRequest, _ what: String) async throws -> Data {
        do { return try await send(req, what) }
        catch let e as URLError {
            throw VoiceError.message("VOICEVOX に接続できません(\(what): \(e.localizedDescription))。VOICEVOX を起動してから、もう一度お試しください。")
        }
    }

    private static func query(_ d: VoicevoxUserDictDraft) -> String {
        "surface=\(encode(d.surface))&pronunciation=\(encode(d.pronunciation))&accent_type=\(d.accentType)&word_type=\(encode(d.wordType))&priority=\(d.priority)"
    }

    /// GET /user_dict
    public func userDict() async throws -> [VoicevoxUserDictWord] {
        let data = try await userDictSend(URLRequest(url: try url("/user_dict")), "user_dict")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VoiceError.badResponse("user_dict") }
        return obj.compactMap { (uuid, v) -> VoicevoxUserDictWord? in
            guard let w = v as? [String: Any], let surface = w["surface"] as? String, let pron = w["pronunciation"] as? String else { return nil }
            return VoicevoxUserDictWord(uuid: uuid, surface: surface, pronunciation: pron,
                                        accentType: (w["accent_type"] as? NSNumber)?.intValue ?? 0,
                                        wordType: w["word_type"] as? String ?? VoicevoxUserDictDraft.defaultWordType,
                                        priority: (w["priority"] as? NSNumber)?.intValue ?? VoicevoxUserDictDraft.defaultPriority)
        }.sorted { $0.uuid < $1.uuid }
    }

    /// POST /user_dict_word → 追加した語の uuid。
    @discardableResult
    public func addUserDictWord(_ d: VoicevoxUserDictDraft) async throws -> String {
        var req = URLRequest(url: try url("/user_dict_word?" + Self.query(d)))
        req.httpMethod = "POST"
        let data = try await userDictSend(req, "user_dict_word 追加")
        // 応答は JSON の文字列("uuid")
        if let s = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String { return s }
        throw VoiceError.badResponse("user_dict_word 追加")
    }

    /// PUT /user_dict_word/{uuid}
    public func updateUserDictWord(uuid: String, _ d: VoicevoxUserDictDraft) async throws {
        var req = URLRequest(url: try url("/user_dict_word/\(Self.encode(uuid))?" + Self.query(d)))
        req.httpMethod = "PUT"
        _ = try await userDictSend(req, "user_dict_word 更新")
    }

    /// DELETE /user_dict_word/{uuid}
    public func deleteUserDictWord(uuid: String) async throws {
        var req = URLRequest(url: try url("/user_dict_word/\(Self.encode(uuid))"))
        req.httpMethod = "DELETE"
        _ = try await userDictSend(req, "user_dict_word 削除")
    }

    /// アプリの辞書をエンジンへ反映する(取得 → 差分計画 → 追加・更新・削除)。
    /// 取得に失敗(未起動など)したら例外。語ごとの失敗は止めずに集めて返す。
    public func syncUserDict(entries: [ReadingEntry], deleteExtras: Bool = false) async throws -> VoicevoxUserDictSync.Report {
        let plan = VoicevoxUserDictSync.plan(entries: entries, engine: try await userDict(), deleteExtras: deleteExtras)
        var report = VoicevoxUserDictSync.Report()
        report.unchanged = plan.unchanged
        for d in plan.adds {
            do { _ = try await addUserDictWord(d); report.added += 1 }
            catch { report.failures.append("\(d.surface): \(error.localizedDescription)") }
        }
        for (uuid, d) in plan.updates {
            do { try await updateUserDictWord(uuid: uuid, d); report.updated += 1 }
            catch { report.failures.append("\(d.surface): \(error.localizedDescription)") }
        }
        for w in plan.deletes {
            do { try await deleteUserDictWord(uuid: w.uuid); report.deleted += 1 }
            catch { report.failures.append("\(w.surface): \(error.localizedDescription)") }
        }
        return report
    }
}
