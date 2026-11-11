import XCTest
@testable import MovieCutCore

final class FirstRunGuideTests: XCTestCase {
    func testDefaultCharacterOrder() {
        XCTAssertEqual(Character.defaults().map(\.name), ["キャラ1", "キャラ2", "キャラ3"])
        XCTAssertEqual(Character.defaults().map(\.color), ["#e8384f", "#f2c53d", "#7ac943"])
    }

    func testDefaultsHaveNoVoiceChosen() {
        XCTAssertTrue(Character.defaults().allSatisfy { !$0.hasVoiceChosen })
    }

    func testHasVoiceChosen() {
        var c = Character()
        c.engine = "voicevox"
        XCTAssertFalse(c.hasVoiceChosen)
        c.speaker = 3
        XCTAssertTrue(c.hasVoiceChosen)
        c.engine = "aquestalk"
        XCTAssertFalse(c.hasVoiceChosen)
        c.voice = "f1"
        XCTAssertTrue(c.hasVoiceChosen)
    }

    func testQuickStartSteps() {
        XCTAssertEqual(QuickStart.steps.count, 4)
        XCTAssertTrue(QuickStart.steps[3].contains("⌘E"))
    }

    func testFetchOutcome() async {
        let ok = VoicePresetCatalog(presets: [])
        let o1 = await VoicePresetFetchOutcome.run { ok }
        XCTAssertEqual(o1, .empty)
        let o2 = await VoicePresetFetchOutcome.run { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(o2, .failed(VoicePresetFetchOutcome.networkFailureMessage))
        let o3 = await VoicePresetFetchOutcome.run { throw VoicePresetCatalog.Failure.tooLarge }
        XCTAssertEqual(o3, .failed(VoicePresetCatalog.Failure.tooLarge.localizedDescription))
    }
}
