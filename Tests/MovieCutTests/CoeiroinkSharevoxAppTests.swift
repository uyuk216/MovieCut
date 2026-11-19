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
        // R3-2: アプリ配線は自動判定プロバイダ(v2 応答時は v2、無応答時は従来 v1 へ委譲)
        let coeiro = try XCTUnwrap(try host.voiceProviderIfAvailable(forEngine: "coeiroink") as? CoeiroinkAutoProvider)
        XCTAssertEqual(coeiro.baseURL, "http://127.0.0.1:50032")
        XCTAssertEqual(coeiro.v1Provider.spec, CoeiroinkPlugin.spec)
        XCTAssertEqual(coeiro.v1Provider.baseURL, "http://127.0.0.1:50032")
        XCTAssertEqual(coeiro.v2Provider.baseURL, "http://127.0.0.1:50032")
        // v1 のアクセント差し替えが配線切替で失われないよう、アクセント対応のままであること
        XCTAssertTrue(coeiro is any VoicevoxAccentProviding)
        XCTAssertTrue(host.isLoaded(pluginID: CoeiroinkPlugin.manifest.id))

        let share = try XCTUnwrap(try host.voiceProviderIfAvailable(forEngine: "sharevox") as? VoicevoxFamilyPluginProvider)
        XCTAssertEqual(share.spec, SharevoxPlugin.spec)
        XCTAssertEqual(share.baseURL, "http://127.0.0.1:50025")
    }
}
