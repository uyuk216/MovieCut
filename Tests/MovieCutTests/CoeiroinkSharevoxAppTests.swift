import XCTest
import MovieCutCore
@testable import MovieCut

/// W3-09 アプリ側配線: AppServices のプラグインホストに COEIROINK / SHAREVOX が登録され、
/// キャラの engine で解決できること(実エンジンには接続しない)。
final class CoeiroinkSharevoxAppTests: XCTestCase {
    func testPluginHostRegistersFamilyPlugins() throws {
        let host = AppServices.makePluginHost(for: Project.new())
        let ids = host.registeredManifests.map(\.id)
        XCTAssertTrue(ids.contains(CoeiroinkPlugin.manifest.id))
        XCTAssertTrue(ids.contains(SharevoxPlugin.manifest.id))
        // 既存プラグインも従来どおり登録されている
        XCTAssertTrue(ids.contains(VoicevoxPlugin.manifest.id))
        XCTAssertTrue(ids.contains(AquesTalkPlugin.manifest.id))

        XCTAssertFalse(host.isLoaded(pluginID: CoeiroinkPlugin.manifest.id))
        let coeiro = try XCTUnwrap(try host.voiceProviderIfAvailable(forEngine: "coeiroink") as? VoicevoxFamilyPluginProvider)
        XCTAssertEqual(coeiro.spec, CoeiroinkPlugin.spec)
        XCTAssertEqual(coeiro.baseURL, "http://127.0.0.1:50032")
        XCTAssertTrue(host.isLoaded(pluginID: CoeiroinkPlugin.manifest.id))

        let share = try XCTUnwrap(try host.voiceProviderIfAvailable(forEngine: "sharevox") as? VoicevoxFamilyPluginProvider)
        XCTAssertEqual(share.spec, SharevoxPlugin.spec)
        XCTAssertEqual(share.baseURL, "http://127.0.0.1:50025")
    }
}
