import XCTest
import MovieCutCore
@testable import MovieCut

/// 多言語: メニューの仕様表の題が英訳を持つこと、日本語では表示が変わらないこと、トップのメニュー名が MenuOrder で並べられること。
@MainActor
final class L10nAppTests: XCTestCase {
    override func tearDown() { L10n.force(nil) }

    private func loadedState() -> MenuState {
        var s = MenuState()
        s.hasDocument = true; s.canExport = true
        s.resolutionKey = "1920x1080"; s.codec = "h264"; s.bg = "#000000"
        return s
    }

    /// 初回起動で見えるメニューの仕様表(ファイル・編集・クリップ・再生・移動・出力)の題。
    private func visibleTitles() -> [String] {
        let s = loadedState()
        var specs: [MenuItemSpec] = []
        specs += AppMenuSpec.file(s)
        specs += [AppMenuSpec.about, AppMenuSpec.settings(s), AppMenuSpec.subtitleImport(s), AppMenuSpec.mediaRelink(s), AppMenuSpec.unusedMediaItem(s),
                  AppMenuSpec.restoreVersionItem(s), AppMenuSpec.packageSave(s), AppMenuSpec.addSubtitle(s), AppMenuSpec.findReplace(s),
                  AppMenuSpec.templateSave(s), AppMenuSpec.aiScript(s), AppMenuSpec.aiSettings(s), AppMenuSpec.welcomeToggle(s)]
        specs += AppMenuSpec.clipboardItems(s)
        specs += AppMenuSpec.editAdd(s)
        specs += AppMenuSpec.clipMenu(s).flatMap { $0 }
        specs += AppMenuSpec.playback(s)
        specs += AppMenuSpec.gotoEnds(s) + AppMenuSpec.gotoNeighbours(s) + [AppMenuSpec.gotoTime(s)] + AppMenuSpec.markerItems(s)
        specs += [AppMenuSpec.exportCurrent(s), AppMenuSpec.videoSettings(s), AppMenuSpec.gifExport(s), AppMenuSpec.apngExport(s)]
        specs += AppMenuSpec.rangeItems(s) + AppMenuSpec.imageExportItems(s) + AppMenuSpec.exportQueueItems(s)
        return specs.map(\.title).filter { !$0.contains("\\(") }
    }

    func testMenuSpecTitlesResolveInEnglish() {
        let titles = visibleTitles()
        XCTAssertGreaterThan(titles.count, 100)
        // ファイル・編集の標準項目は SwiftUI が持つ(システムの言語で出る)。ここは仕様表の題だけを見る
        let missing = Set(titles.filter { !L10n.hasEnglish($0) }).sorted()
        XCTAssertEqual(missing, [], "英訳が無いメニューの題: \(missing)")
    }

    func testJapaneseDisplayIsUnchanged() {
        L10n.force(.ja)
        for s in [AppMenuSpec.about, AppMenuSpec.settings(loadedState())] {
            XCTAssertEqual(s.localizedTitle, s.displayTitle)
        }
        let enter = AppMenuSpec.clipEdit(loadedState()).first { $0.command == .compoundEnter }!
        XCTAssertEqual(enter.localizedTitle, enter.displayTitle, "ヒント付きでも日本語は同じ")
    }

    func testEnglishDisplayIncludesTranslatedHint() {
        L10n.force(.en)
        let enter = AppMenuSpec.clipEdit(loadedState()).first { $0.command == .compoundEnter }!
        XCTAssertEqual(enter.localizedTitle, "Edit Inside Compound Clip  (You can also double-click a compound clip in the timeline)")
        XCTAssertEqual(AppMenuSpec.about.localizedTitle, "About Movie Cut")
    }

    func testTopLevelMenuNamesStayOrderableInEnglish() {
        for ja in MenuOrder.desired {
            let en = L10n.t(ja, in: .en)
            XCTAssertEqual(MenuOrder.rank(of: en), MenuOrder.rank(of: ja), "\(ja) → \(en)")
        }
        let english = MenuOrder.desired.map { L10n.t($0, in: .en) }
        XCTAssertEqual(MenuOrder.ordered(["Movie Cut"] + english.reversed()), ["Movie Cut"] + english)
    }

    func testPanelTitlesAndLayoutNamesAreTranslated() {
        for p in DockPanel.allCases { XCTAssertTrue(L10n.hasEnglish(p.title), p.title) }
        for l in DockPreset.allCases { XCTAssertTrue(L10n.hasEnglish(l.title), l.title) }
    }
}
