import XCTest
import MovieCutCore
@testable import MovieCut

/// インスペクタの節の開閉: アプリ側の保存(AppStorage と同じ UserDefaults.standard のキー)の往復と、カタログの完全性。
/// 本番の UserDefaults.standard を触るので、テスト前に全キーの既存値を退避し、テスト後に元へ戻す(無かったキーは削除)。
@MainActor
final class InspectorSectionDisclosureAppTests: XCTestCase {
    private var backup: [String: Any] = [:]
    private var keys: [String] { InspectorSectionCatalog.all.map(\.storageKey) }

    override func setUp() {
        let d = UserDefaults.standard
        for k in keys {
            if let v = d.object(forKey: k) { backup[k] = v }
            d.removeObject(forKey: k)   // 各テストは未保存の状態から始める
        }
    }

    override func tearDown() {
        let d = UserDefaults.standard
        for k in keys {
            if let v = backup[k] { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        }
        backup = [:]
    }

    /// アプリ側が参照する節 id の期待集合(Core のテストとは別に、アプリが使う id を明示しておく)。
    private static let expected: Set<String> = {
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
        ]
        for k in ["filter", "peq", "dist", "tube", "chorus", "flanger", "phaser", "tremolo", "vibrato", "wah", "echo", "lowq", "robot"] {
            s.insert("inspector.audioFx.ext.\(k)")
        }
        return s
    }()

    func testCatalogCompleteness() {
        let ids = InspectorSectionCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids), Self.expected)
        XCTAssertEqual(ids.count, Self.expected.count, "重複がある")
        // ビューが `require` で引く id は全部引ける(未登録なら preconditionFailure で落ちるので、事前に確認)
        for id in Self.expected { XCTAssertNotNil(InspectorSectionCatalog.definition(id: id), id) }
    }

    func testPersistenceRoundTripUsesAppStorageKeys() {
        // 保存 → 再読込で一致。AppStorage(`mc.disclosure.<id>`)と同じ UserDefaults.standard のキーに入る。
        InspectorDisclosurePersistence.save(true, id: "inspector.audioFx.eq")
        InspectorDisclosurePersistence.save(false, id: "inspector.audioFx.vst3")
        XCTAssertEqual(UserDefaults.standard.object(forKey: "mc.disclosure.inspector.audioFx.eq") as? Bool, true)
        XCTAssertEqual(InspectorDisclosurePersistence.saved("inspector.audioFx.eq"), true)
        XCTAssertEqual(InspectorDisclosurePersistence.saved("inspector.audioFx.vst3"), false)
        // 逆向き: AppStorage(MCDisclosure)が書いた値を、永続化ヘルパが読める
        UserDefaults.standard.set(true, forKey: InspectorSectionCatalog.require("inspector.textStyle.balloon").storageKey)
        XCTAssertEqual(InspectorDisclosurePersistence.saved("inspector.textStyle.balloon"), true)
    }

    func testUnsavedStaysNilSoDefaultRuleApplies() {
        // 未保存は nil → 「効いている節だけ開く」の既定判定が生きる(固定値を保存しない)
        for d in InspectorSectionCatalog.all where d.defaultsToActive {
            XCTAssertNil(InspectorDisclosurePersistence.saved(d.id), d.id)
        }
        XCTAssertTrue(InspectorDisclosurePersistence.savedExtended().isEmpty)
    }

    func testExtendedSavedRoundTrip() {
        InspectorDisclosurePersistence.save(true, id: "inspector.audioFx.ext.wah")
        InspectorDisclosurePersistence.save(false, id: "inspector.audioFx.ext.echo")
        XCTAssertEqual(InspectorDisclosurePersistence.savedExtended(), ["wah": true, "echo": false])
    }

    func testExistingTopLevelKeysKeepSavedState() {
        // 既存ユーザーの保存済み状態(従来の実キー)を、カタログ経由でもそのまま読める
        UserDefaults.standard.set(false, forKey: "mc.disclosure.inspector.timing")
        XCTAssertEqual(InspectorDisclosurePersistence.saved("inspector.timing"), false)
        XCTAssertEqual(InspectorSectionCatalog.require("inspector.timing").storageKey, "mc.disclosure.inspector.timing")
    }
}
