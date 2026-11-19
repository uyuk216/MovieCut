import XCTest
@testable import MovieCutCore

/// 素材メタデータ(キーワード・評価・メモ・ラベル)とスマートコレクション。
/// 保存の往復、未使用時のバイト一致、絞り込み条件の AND / OR、コレクションの一致判定を見る。
final class MediaMetadataTests: XCTestCase {
    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: 保存と復元

    func testUnusedProjectHasNoMetadataKeysAndIsByteStable() throws {
        var p = Project.new()
        p.mediaPool = ["/m/a.mp4", "/m/b.wav"]
        let data1 = try p.encoded()
        let text = String(decoding: data1, as: UTF8.self)
        XCTAssertFalse(text.contains("\"mediaMetadata\""), "使っていないのに mediaMetadata が書かれた")
        XCTAssertFalse(text.contains("\"smartCollections\""), "使っていないのに smartCollections が書かれた")
        // 往復してもバイトが変わらない(従来形式のまま)
        let decoded = try Project.decode(from: data1)
        XCTAssertEqual(try decoded.encoded(), data1)
        XCTAssertTrue(decoded.mediaMetadata.isEmpty)
        XCTAssertTrue(decoded.smartCollections.isEmpty)
    }

    func testEmptyMetadataIsDroppedAndNotWritten() throws {
        var p = Project.new()
        MediaMetadataEditing.set(MediaMetadata(), for: "/m/a.mp4", in: &p)
        XCTAssertTrue(p.mediaMetadata.isEmpty, "空のメタデータは項目ごと残らない")
        let text = String(decoding: try p.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("\"mediaMetadata\""))
    }

    func testMetadataRoundTrip() throws {
        var p = Project.new()
        p.mediaPool = ["/m/a.mp4", "/m/b.wav"]
        MediaMetadataEditing.set(MediaMetadata(keywords: ["海", "夕焼け"], rating: 4, note: "オープニング用", label: "blue"), for: "/m/a.mp4", in: &p)
        MediaMetadataEditing.set(MediaMetadata(rating: 0), for: "/m/b.wav", in: &p)
        let data = try p.encoded()
        let decoded = try Project.decode(from: data)
        XCTAssertEqual(decoded, p)
        XCTAssertEqual(decoded.mediaMetadata["/m/a.mp4"]?.keywords, ["海", "夕焼け"])
        XCTAssertEqual(decoded.mediaMetadata["/m/a.mp4"]?.rating, 4)
        XCTAssertEqual(decoded.mediaMetadata["/m/a.mp4"]?.note, "オープニング用")
        XCTAssertEqual(decoded.mediaMetadata["/m/a.mp4"]?.label, "blue")
        XCTAssertEqual(decoded.mediaMetadata["/m/b.wav"]?.rating, 0, "評価 0 も未評価と区別して残る")
    }

    func testOnlySetFieldsAreWritten() throws {
        var p = Project.new()
        MediaMetadataEditing.set(MediaMetadata(rating: 3), for: "/m/a.mp4", in: &p)
        let root = try jsonObject(try p.encoded())
        let all = try XCTUnwrap(root["mediaMetadata"] as? [String: Any])
        let one = try XCTUnwrap(all["/m/a.mp4"] as? [String: Any])
        XCTAssertEqual(Set(one.keys), ["rating"], "設定した項目だけを書く")
    }

    func testMetadataNormalization() {
        let m = MediaMetadata(keywords: [" 海 ", "海", "UMI", "umi", "", "  "], rating: 9, note: "   ", label: " ")
        XCTAssertEqual(m.keywords, ["海", "UMI"], "空白を取り除き、空と重複(大文字小文字を無視)を除く")
        XCTAssertEqual(m.rating, 5, "評価は 0〜5 に収める")
        XCTAssertNil(m.note, "空白だけのメモは未設定")
        XCTAssertNil(m.label)
        XCTAssertEqual(MediaMetadata(rating: -3).rating, 0)
    }

    func testUnknownKeysInsideMetadataAndCollectionArePreserved() throws {
        let json = """
        {"mediaMetadata": {"/m/a.mp4": {"keywords": ["海"], "futureMetaKey": 7}},
         "smartCollections": [{"id": "c1", "name": "海素材", "criteria": {"keywords": ["海"]}, "futureColKey": "x"}],
         "futureProjectKey": true}
        """
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertEqual(p.mediaMetadata["/m/a.mp4"]?.keywords, ["海"])
        XCTAssertEqual(p.mediaMetadata["/m/a.mp4"]?.extra["futureMetaKey"], .number(7))
        XCTAssertEqual(p.smartCollections.first?.extra["futureColKey"], .string("x"))
        let text = String(decoding: try p.encoded(), as: UTF8.self)
        for k in ["futureMetaKey", "futureColKey", "futureProjectKey"] {
            XCTAssertTrue(text.contains(k), "\(k) が書き戻されていない")
        }
        XCTAssertEqual(try Project.decode(from: p.encoded()), p)
    }

    func testMalformedMetadataIsKeptInExtra() throws {
        let json = #"{"mediaMetadata": "broken", "smartCollections": 42}"#
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertTrue(p.mediaMetadata.isEmpty)
        XCTAssertTrue(p.smartCollections.isEmpty)
        let text = String(decoding: try p.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\"mediaMetadata\""), "型が違う値は捨てずに書き戻す")
        XCTAssertTrue(text.contains("\"smartCollections\""))
    }

    // MARK: 絞り込み条件(AND / OR の意味)

    private func meta(keywords: [String] = [], rating: Int? = nil, note: String? = nil, label: String? = nil) -> MediaMetadata {
        MediaMetadata(keywords: keywords, rating: rating, note: note, label: label)
    }

    func testKeywordConditionAllIsAndAnyIsOr() {
        let m = meta(keywords: ["海", "夕焼け"])
        let both = ["海", "夕焼け"]
        XCTAssertTrue(MediaFilterCriteria(keywords: both, keywordMode: .all).matches(name: "a.mp4", kind: .video, metadata: m))
        XCTAssertTrue(MediaFilterCriteria(keywords: both, keywordMode: .any).matches(name: "a.mp4", kind: .video, metadata: m))
        let mixed = ["海", "山"]
        XCTAssertFalse(MediaFilterCriteria(keywords: mixed, keywordMode: .all).matches(name: "a.mp4", kind: .video, metadata: m), "all は全部そろわないと不一致")
        XCTAssertTrue(MediaFilterCriteria(keywords: mixed, keywordMode: .any).matches(name: "a.mp4", kind: .video, metadata: m), "any は 1 つでもあれば一致")
        XCTAssertFalse(MediaFilterCriteria(keywords: ["山"], keywordMode: .any).matches(name: "a.mp4", kind: .video, metadata: m))
        XCTAssertFalse(MediaFilterCriteria(keywords: ["海"]).matches(name: "a.mp4", kind: .video, metadata: nil), "メタデータが無い素材はキーワード条件に合わない")
    }

    func testDimensionsCombineWithAnd() {
        let m = meta(keywords: ["海"], rating: 2, label: "blue")
        var c = MediaFilterCriteria(keywords: ["海"], minRating: 4)
        XCTAssertFalse(c.matches(name: "a.mp4", kind: .video, metadata: m), "キーワードが合っても評価が届かなければ不一致(項目間は AND)")
        c.minRating = 2
        XCTAssertTrue(c.matches(name: "a.mp4", kind: .video, metadata: m))
        c.label = "red"
        XCTAssertFalse(c.matches(name: "a.mp4", kind: .video, metadata: m), "ラベル違いは不一致")
        c.label = "blue"; c.kind = "audio"
        XCTAssertFalse(c.matches(name: "a.mp4", kind: .video, metadata: m), "種類違いは不一致")
        c.kind = "video"
        XCTAssertTrue(c.matches(name: "a.mp4", kind: .video, metadata: m))
    }

    func testMinRatingAndUnrated() {
        XCTAssertFalse(MediaFilterCriteria(minRating: 1).matches(name: "a.mp4", kind: .video, metadata: nil), "下限が正なら未評価は不一致")
        XCTAssertTrue(MediaFilterCriteria(minRating: 0).matches(name: "a.mp4", kind: .video, metadata: nil), "下限 0 は未評価も一致")
        XCTAssertTrue(MediaFilterCriteria(minRating: 3).matches(name: "a.mp4", kind: .video, metadata: meta(rating: 3)))
        XCTAssertFalse(MediaFilterCriteria(minRating: 3).matches(name: "a.mp4", kind: .video, metadata: meta(rating: 2)))
        XCTAssertTrue(MediaFilterCriteria().matches(name: "a.mp4", kind: .video, metadata: nil), "空の条件は全部に一致")
    }

    func testTextTermsAreAndAcrossFieldsOr() {
        let m = meta(keywords: ["夕焼け"], note: "オープニングで使う")
        // 語は 名前・キーワード・メモ のどこかにあればよい(OR)、語同士は AND
        XCTAssertTrue(MediaFilterCriteria(text: "夕焼け オープニング").matches(name: "clip.mp4", kind: .video, metadata: m))
        XCTAssertTrue(MediaFilterCriteria(text: "clip 夕焼け").matches(name: "clip.mp4", kind: .video, metadata: m), "名前にも当たる")
        XCTAssertFalse(MediaFilterCriteria(text: "夕焼け 山").matches(name: "clip.mp4", kind: .video, metadata: m), "1 語でも欠ければ不一致")
        XCTAssertTrue(MediaFilterCriteria(text: "YUYAKE").matches(name: "clip.mp4", kind: .video, metadata: meta(keywords: ["yuyake"])), "大文字小文字を無視")
    }

    // MARK: スマートコレクション

    private func sampleProject() -> Project {
        var p = Project.new()
        p.mediaPool = ["/m/sea.mp4", "/m/mountain.mp4", "/m/sea-bgm.wav", "/m/city.png"]
        MediaMetadataEditing.set(meta(keywords: ["海"], rating: 5, label: "blue"), for: "/m/sea.mp4", in: &p)
        MediaMetadataEditing.set(meta(keywords: ["山"], rating: 3), for: "/m/mountain.mp4", in: &p)
        MediaMetadataEditing.set(meta(keywords: ["海"], rating: 4), for: "/m/sea-bgm.wav", in: &p)
        return p
    }

    func testSmartCollectionMatchesSubset() {
        let p = sampleProject()
        let sea = SmartCollection(name: "海の高評価", criteria: MediaFilterCriteria(keywords: ["海"], minRating: 4))
        XCTAssertEqual(MediaMetadataEditing.sources(in: p, matching: sea), ["/m/sea.mp4", "/m/sea-bgm.wav"])
        let seaVideo = SmartCollection(name: "海の動画", criteria: MediaFilterCriteria(keywords: ["海"], kind: "video"))
        XCTAssertEqual(MediaMetadataEditing.sources(in: p, matching: seaVideo), ["/m/sea.mp4"], "種類も AND で効く")
        let any = SmartCollection(name: "海か山", criteria: MediaFilterCriteria(keywords: ["海", "山"], keywordMode: .any))
        XCTAssertEqual(MediaMetadataEditing.sources(in: p, matching: any), ["/m/sea.mp4", "/m/mountain.mp4", "/m/sea-bgm.wav"])
        let none = SmartCollection(name: "空", criteria: MediaFilterCriteria(keywords: ["雪"]))
        XCTAssertEqual(MediaMetadataEditing.sources(in: p, matching: none), [])
    }

    func testSmartCollectionRoundTrip() throws {
        var p = sampleProject()
        let made = MediaMetadataEditing.addCollection(name: "海の高評価", criteria: MediaFilterCriteria(keywords: ["海"], keywordMode: .any, minRating: 4, label: "blue", kind: "video"), in: &p)
        MediaMetadataEditing.addCollection(name: "条件なし", criteria: MediaFilterCriteria(), in: &p)
        let data = try p.encoded()
        let decoded = try Project.decode(from: data)
        XCTAssertEqual(decoded, p)
        XCTAssertEqual(decoded.smartCollections.count, 2)
        XCTAssertEqual(decoded.smartCollections[0].id, made.id)
        XCTAssertEqual(decoded.smartCollections[0].criteria.keywordMode, .any)
        // 条件が空のコレクションは criteria キーを持たない(id と名前だけ)
        let root = try jsonObject(data)
        let cols = try XCTUnwrap(root["smartCollections"] as? [[String: Any]])
        XCTAssertEqual(Set(cols[1].keys), ["id", "name"])
        // 既定(all)の keywordMode は書かない
        var q = Project.new()
        MediaMetadataEditing.addCollection(name: "x", criteria: MediaFilterCriteria(keywords: ["a"]), in: &q)
        let root2 = try jsonObject(try q.encoded())
        let cols2 = try XCTUnwrap(root2["smartCollections"] as? [[String: Any]])
        let crit = try XCTUnwrap(cols2[0]["criteria"] as? [String: Any])
        XCTAssertEqual(Set(crit.keys), ["keywords"], "既定値の項目は書かない")
    }

    func testCollectionUpdateAndRemove() {
        var p = sampleProject()
        let c = MediaMetadataEditing.addCollection(name: "仮", criteria: MediaFilterCriteria(), in: &p)
        var edited = c; edited.name = "本名"; edited.criteria = MediaFilterCriteria(minRating: 5)
        MediaMetadataEditing.updateCollection(edited, in: &p)
        XCTAssertEqual(p.smartCollections.first?.name, "本名")
        XCTAssertEqual(MediaMetadataEditing.sources(in: p, matching: edited), ["/m/sea.mp4"])
        MediaMetadataEditing.removeCollection(id: c.id, in: &p)
        XCTAssertTrue(p.smartCollections.isEmpty)
        XCTAssertFalse(p.mediaMetadata.isEmpty, "コレクションを消してもメタデータは残る")
    }

    func testFilteredSourcesUsesClipsAndPool() {
        var p = sampleProject()
        var clip = Clip(); clip.type = .video; clip.src = "/m/extra.mp4"
        p.tracks[0].clips = [clip]
        MediaMetadataEditing.set(meta(keywords: ["海"]), for: "/m/extra.mp4", in: &p)
        XCTAssertEqual(MediaMetadataEditing.filteredSources(in: p, criteria: MediaFilterCriteria(keywords: ["海"])),
                       ["/m/extra.mp4", "/m/sea.mp4", "/m/sea-bgm.wav"], "クリップの素材が先(mediaPool との和集合)")
    }

    func testAllKeywordsOrderedByCountThenName() {
        let p = sampleProject()
        XCTAssertEqual(MediaMetadataEditing.allKeywords(in: p), ["海", "山"], "海は 2 件、山は 1 件")
    }

    func testEditingHelpersAddAndRemoveKeyword() {
        var p = Project.new()
        MediaMetadataEditing.addKeyword(" 海 ", for: "/m/a.mp4", in: &p)
        MediaMetadataEditing.addKeyword("海", for: "/m/a.mp4", in: &p)
        XCTAssertEqual(p.mediaMetadata["/m/a.mp4"]?.keywords, ["海"], "重複は足されない")
        MediaMetadataEditing.removeKeyword("海", for: "/m/a.mp4", in: &p)
        XCTAssertTrue(p.mediaMetadata.isEmpty, "最後の項目が無くなれば項目ごと消える")
        MediaMetadataEditing.update(for: "/m/a.mp4", in: &p, rating: .some(.some(4)), note: .some(nil))
        XCTAssertEqual(p.mediaMetadata["/m/a.mp4"]?.rating, 4)
        XCTAssertNil(p.mediaMetadata["/m/a.mp4"]?.note)
    }

    // MARK: 素材ブラウザとの接続

    func testBrowserFilterWithMetadata() {
        func item(_ name: String) -> MediaBrowser.Item {
            MediaBrowser.Item(url: URL(fileURLWithPath: "/x/\(name)"), name: name, kind: MediaBrowser.kind(forName: name) ?? .video)
        }
        let items = ["sea.mp4", "mountain.mp4", "sea-bgm.wav"].map(item)
        let metadata: [String: MediaMetadata] = [
            "/x/sea.mp4": meta(keywords: ["海"], rating: 5),
            "/x/mountain.mp4": meta(keywords: ["山"], rating: 3),
            "/x/sea-bgm.wav": meta(keywords: ["海"], rating: 1),
        ]
        // 空の条件は素の filter と同じ
        XCTAssertEqual(MediaBrowser.filter(items, kind: .all, query: "", metadata: metadata, criteria: MediaFilterCriteria()).map(\.name),
                       MediaBrowser.filter(items, kind: .all, query: "").map(\.name))
        // キーワード + 評価の下限
        let c = MediaFilterCriteria(keywords: ["海"], minRating: 4)
        XCTAssertEqual(MediaBrowser.filter(items, kind: .all, query: "", metadata: metadata, criteria: c).map(\.name), ["sea.mp4"])
        // 自由文はメモにも当たる
        let withNote: [String: MediaMetadata] = ["/x/mountain.mp4": meta(note: "オープニング候補")]
        XCTAssertEqual(MediaBrowser.filter(items, kind: .all, query: "", metadata: withNote, criteria: MediaFilterCriteria(text: "オープニング")).map(\.name), ["mountain.mp4"])
        // 種類の絞り込み(既存)と条件は AND
        XCTAssertEqual(MediaBrowser.filter(items, kind: .audio, query: "", metadata: metadata, criteria: MediaFilterCriteria(keywords: ["海"])).map(\.name), ["sea-bgm.wav"])
    }
}
