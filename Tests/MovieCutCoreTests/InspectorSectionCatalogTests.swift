import XCTest
@testable import MovieCutCore

/// インスペクタの節カタログの整合と、開閉状態の保存の往復。
/// 保存の確認は専用 suite だけを使い、後片付けで suite ごと消す(本番の UserDefaults.standard には書かない)。
final class InspectorSectionCatalogTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "InspectorSectionCatalogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    /// 期待するセクション id の全集合。節を足す・消すときはカタログとここを同時に直す(漏れ・余りを検出する)。
    static let expectedIDs: Set<String> = {
        var s: Set<String> = [
            "inspector.timing", "inspector.note", "inspector.group", "inspector.voice", "inspector.text", "inspector.textStyle",
            "inspector.place", "inspector.compound", "inspector.scene", "inspector.effect", "inspector.transition",
            "inspector.blur", "inspector.visualizer", "inspector.shape", "inspector.speed", "inspector.stabilize",
            "inspector.mask", "inspector.audio",
            "inspector.tracking", "inspector.objectMask", "inspector.hslMask", "inspector.warpMesh", "inspector.warpPuppet", "inspector.camera",
            "inspector.audioFx.basic", "inspector.audioFx.eq", "inspector.audioFx.comp", "inspector.audioFx.reverb",
            "inspector.audioFx.delay", "inspector.audioFx.norm", "inspector.audioFx.duck", "inspector.audioFx.vst3",
            "inspector.place.position", "inspector.place.transform", "inspector.place.crop", "inspector.place.look",
            "inspector.blur.range", "inspector.blur.look",
            "inspector.visualizer.range", "inspector.visualizer.input", "inspector.visualizer.look",
            "inspector.shape.range", "inspector.shape.look",
            "inspector.voice.subtitle", "inspector.voice.audio",
            "inspector.textStyle.balloon", "inspector.textStyle.style", "inspector.textStyle.decoration",
            "inspector.textStyle.countdown", "inspector.textStyle.otherClips", "inspector.textStyle.animation",
            "inspector.tachie.main", "inspector.tachie.expression", "inspector.tachie.image", "inspector.tachie.mouth",
            "inspector.rig.parts", "inspector.rig.expressions",
            "inspector.character.basic", "inspector.character.voice", "inspector.character.actions",
        ]
        for k in ["filter", "peq", "dist", "tube", "chorus", "flanger", "phaser", "tremolo", "vibrato", "wah", "echo", "lowq", "robot"] {
            s.insert("inspector.audioFx.ext.\(k)")
        }
        return s
    }()

    func testIDsAndStorageKeysAreUnique() {
        let all = InspectorSectionCatalog.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "id が重複している")
        XCTAssertEqual(Set(all.map(\.storageKey)).count, all.count, "storageKey が重複している")
    }

    func testStorageKeysFollowNamingRule() {
        for d in InspectorSectionCatalog.all {
            XCTAssertTrue(d.storageKey.hasPrefix("mc.disclosure."), d.storageKey)
            XCTAssertEqual(d.storageKey, "mc.disclosure." + d.id)
            XCTAssertTrue(InspectorSectionCatalog.isValidStorageKey(d.storageKey), "命名規則に反する: \(d.storageKey)")
            XCTAssertFalse(d.title.isEmpty)
        }
        XCTAssertFalse(InspectorSectionCatalog.isValidStorageKey("inspector.timing"))
        XCTAssertFalse(InspectorSectionCatalog.isValidStorageKey("mc.disclosure."))
        XCTAssertFalse(InspectorSectionCatalog.isValidStorageKey("mc.disclosure.inspector..x"))
        XCTAssertFalse(InspectorSectionCatalog.isValidStorageKey("mc.disclosure.inspector.a-b"))
        XCTAssertFalse(InspectorSectionCatalog.isValidStorageKey("mc.disclosure.インスペクタ"))
    }

    func testCatalogMatchesExpectedSetExactly() {
        let ids = InspectorSectionCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids), Self.expectedIDs)
        XCTAssertEqual(ids.count, Self.expectedIDs.count)
        XCTAssertEqual(Set(Self.expectedIDs).subtracting(ids), [], "カタログに漏れ")
        XCTAssertEqual(Set(ids).subtracting(Self.expectedIDs), [], "カタログに余り")
    }

    func testExistingTopLevelKeysAreUnchanged() {
        // 既存ユーザーの保存済み状態を引き継ぐため、従来の実キーと既定を固定する。
        let legacy: [(String, Bool)] = [("timing", true), ("note", false), ("group", false), ("voice", true), ("text", true), ("textStyle", true),
                                        ("place", true), ("compound", false), ("scene", true), ("effect", false), ("transition", false),
                                        ("blur", true), ("visualizer", true), ("shape", true), ("speed", false), ("stabilize", false),
                                        ("mask", false), ("audio", true)]
        for (k, open) in legacy {
            let d = InspectorSectionCatalog.require("inspector.\(k)")
            XCTAssertEqual(d.storageKey, "mc.disclosure.inspector.\(k)")
            XCTAssertEqual(d.defaultOpen, open, k)
        }
    }

    func testExtendedKeysCoverCatalog() {
        for k in InspectorSectionCatalog.audioFxExtendedKeys {
            XCTAssertNotNil(InspectorSectionCatalog.definition(id: "inspector.audioFx.ext.\(k)"), k)
        }
        XCTAssertEqual(InspectorSectionCatalog.audioFxExtendedKeys.count, 13)
    }

    func testStoreRoundTripWithInjectedDefaults() throws {
        let store = InspectorDisclosureStore(defaults: defaults)
        for d in InspectorSectionCatalog.all {
            XCTAssertNil(store.saved(d), "未保存のはず: \(d.id)")
            XCTAssertEqual(store.resolved(d, fallback: d.defaultOpen), d.defaultOpen)
        }
        let eq = InspectorSectionCatalog.require("inspector.audioFx.eq")
        store.set(true, for: eq)
        XCTAssertEqual(store.saved(eq), true)
        XCTAssertEqual(defaults.object(forKey: "mc.disclosure.inspector.audioFx.eq") as? Bool, true)
        // 保存済みなら fallback(効いている節だけ開く)より保存値が優先される
        store.set(false, for: eq)
        XCTAssertEqual(store.resolved(eq, fallback: true), false)
        // 別インスタンスでも再読込できる(再起動相当)
        XCTAssertEqual(InspectorDisclosureStore(defaults: defaults).saved(id: "inspector.audioFx.eq"), false)
        // 他の節には影響しない
        XCTAssertNil(store.saved(id: "inspector.audioFx.comp"))
        store.clear(eq)
        XCTAssertNil(store.saved(eq))
        XCTAssertEqual(store.resolved(eq, fallback: true), true)
    }

    func testStoreNeverTouchesStandardDefaults() {
        let key = InspectorSectionCatalog.require("inspector.camera").storageKey
        let before = UserDefaults.standard.object(forKey: key)
        InspectorDisclosureStore(defaults: defaults).set(!(before as? Bool ?? true), id: "inspector.camera")
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, before as? Bool)
    }
}
