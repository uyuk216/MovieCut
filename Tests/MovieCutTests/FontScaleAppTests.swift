import XCTest
import MovieCutCore
@testable import MovieCut

@MainActor
final class FontScaleAppTests: XCTestCase {
    override func tearDown() {
        FontScaleStore.resetMemory()
        UserDefaults.standard.removeObject(forKey: FontScaleStore.defaultsKey)
        super.tearDown()
    }

    private func isolated() -> UserDefaults {
        let name = "FontScaleAppTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    func testResolveDefaultsToStandardWhenMissingOrBroken() {
        let d = isolated()
        XCTAssertEqual(FontScaleStore.resolve(d), .standard)
        d.set(99, forKey: FontScaleStore.defaultsKey)
        XCTAssertEqual(FontScaleStore.resolve(d), .standard)
        d.set(-1, forKey: FontScaleStore.defaultsKey)
        XCTAssertEqual(FontScaleStore.resolve(d), .standard)
    }

    func testSetStoresAndNotifies() {
        let d = isolated()
        var posted = 0
        let obs = NotificationCenter.default.addObserver(forName: FontScaleStore.didChange, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(obs); FontScaleStore.set(.standard) }
        FontScaleStore.set(.large, defaults: d)
        XCTAssertEqual(posted, 1)
        // 静かな検証ではメモリ、そうでなければ d に保存される。どちらでも current は変わる。
        XCTAssertEqual(FontScaleStore.current == .large || FontScaleStore.resolve(d) == .large, true)
        if !DebugHooks.isQuiet {
            XCTAssertEqual(d.integer(forKey: FontScaleStore.defaultsKey), FontScaleStep.large.rawValue)
            XCTAssertEqual(FontScaleStore.resolve(d), .large)
        }
    }

    func testFontSizeFollowsStep() {
        defer { FontScaleStore.set(.standard) }
        for s in FontScaleStep.allCases {
            FontScaleStore.set(s)
            XCTAssertEqual(MCDesign.FontSize.headline, s.headingSize)
            XCTAssertEqual(MCDesign.FontSize.callout, s.bodySize)
            XCTAssertEqual(MCDesign.FontSize.title2, s.headingScaled(base: 17))
        }
    }
}
