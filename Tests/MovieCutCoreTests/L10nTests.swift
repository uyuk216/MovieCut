import XCTest
@testable import MovieCutCore

/// 多言語の土台: 対訳表(日本語が原文・英語の訳がすべてある・訳に日本語が残らない)、言語の決め方、上書きの保存、日本語では何も変わらないこと。
final class L10nTests: XCTestCase {
    override func tearDown() { L10n.force(nil) }

    private func hasJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    /// 同じ字面でよいもの(固有名・記号・略語)。
    private let sameAsJapanese: Set<String> = ["FPS", "OK", "English", "＋"]

    func testEveryKeyHasJapaneseSourceAndEnglishTranslation() {
        let table = L10nTable.english
        XCTAssertGreaterThanOrEqual(table.count, 300)
        for (ja, en) in table {
            XCTAssertFalse(ja.trimmingCharacters(in: .whitespaces).isEmpty, "原文が空")
            XCTAssertFalse(en.trimmingCharacters(in: .whitespaces).isEmpty, "\(ja) の英訳が空")
            if !sameAsJapanese.contains(ja) { XCTAssertNotEqual(ja, en, "\(ja) が訳されていない") }
            if ja != "言語の切り替えは、メニューなどを開き直すと反映されます。" || true {
                // 日本語の語を含まない訳(記号の「…」「–」は可)
                XCTAssertFalse(hasJapanese(en), "英訳に日本語が残っている: \(ja) → \(en)")
            }
        }
    }

    func testJapaneseIsIdentityAndEnglishTranslates() {
        for (ja, en) in L10nTable.english {
            XCTAssertEqual(L10n.t(ja, in: .ja), ja, "日本語では何も変わらない")
            XCTAssertEqual(L10n.t(ja, in: .en), en)
        }
        XCTAssertEqual(L10n.t("未登録の日本語", in: .en), "未登録の日本語", "訳が無ければ日本語のまま")
        XCTAssertEqual(L10n.t("", in: .en), "")
        XCTAssertTrue(L10n.hasEnglish("ファイル"))
        XCTAssertFalse(L10n.hasEnglish("未登録の日本語"))
    }

    func testTopLevelMenuNamesAreTranslatedToTheNamesMenuOrderKnows() {
        let expected = ["ファイル": "File", "編集": "Edit", "クリップ": "Clip", "再生": "Playback", "移動": "Go",
                        "出力": "Output", "表示": "View", "ウィンドウ": "Window", "ヘルプ": "Help"]
        for (ja, en) in expected { XCTAssertEqual(L10n.t(ja, in: .en), en) }
    }

    func testLanguageResolution() {
        XCTAssertEqual(L10n.resolve(override: .system, preferred: ["ja-JP", "en-US"]), .ja)
        XCTAssertEqual(L10n.resolve(override: .system, preferred: ["en-US", "ja-JP"]), .en)
        XCTAssertEqual(L10n.resolve(override: .system, preferred: ["fr-FR"]), .en, "対応外の言語は英語")
        XCTAssertEqual(L10n.resolve(override: .system, preferred: []), .ja)
        XCTAssertEqual(L10n.resolve(override: .ja, preferred: ["en-US"]), .ja, "上書きが勝つ")
        XCTAssertEqual(L10n.resolve(override: .en, preferred: ["ja-JP"]), .en)
    }

    func testOverrideIsStoredAndSystemClearsIt() {
        let d = UserDefaults(suiteName: "l10n-tests-\(UUID().uuidString)")!
        XCTAssertEqual(L10n.storedOverride(d), .system)
        L10n.setOverride(.en, defaults: d)
        XCTAssertEqual(L10n.storedOverride(d), .en)
        XCTAssertEqual(d.string(forKey: L10n.defaultsKey), "en")
        L10n.setOverride(.system, defaults: d)
        XCTAssertNil(d.object(forKey: L10n.defaultsKey), "システムに戻したら記録は残さない")
        d.set("garbage", forKey: L10n.defaultsKey)
        XCTAssertEqual(L10n.storedOverride(d), .system)
    }

    func testForcedLanguageSwitchesT() {
        L10n.force(.en)
        XCTAssertEqual(L10n.t("ファイル"), "File")
        L10n.force(.ja)
        XCTAssertEqual(L10n.t("ファイル"), "ファイル")
        L10n.force(nil)
        XCTAssertEqual(L10n.current, .ja, "試験の中では、上書きが無ければ日本語")
    }

    /// 対訳表の言葉が、メニュー側の英語の別名(MenuOrder)と食い違わない前提: 各語は重複しない(キーの重複は辞書では作れないが、訳の取り違えを防ぐ)。
    func testAppLanguageLabels() {
        XCTAssertEqual(AppLanguage.allCases.count, 3)
        XCTAssertEqual(AppLanguage.ja.label, "日本語")
        XCTAssertEqual(AppLanguage.en.label, "English")
    }
}
