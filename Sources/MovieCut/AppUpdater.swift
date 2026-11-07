import Foundation
import MovieCutCore
#if SPARKLE
import Sparkle
#endif

/// 自動アップデート(Sparkle)。配布版(public)でだけ動く。
/// - 個人版は Sparkle をリンクしないので、アップデートの確認は一切しない。
/// - 公開鍵(SUPublicEDKey)が空・未設定のビルド(鍵を渡さずに作った試作)では起動しない
///   (起動すると Sparkle が「アップデータを起動できません」と出すため)。
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    /// アップデートを確認できる状態か(= メニューに項目を出すか)。
    static var isAvailable: Bool {
        #if SPARKLE
        return AppEdition.current == .public && hasValidPublicKey(Bundle.main.infoDictionary)
        #else
        return false
        #endif
    }

    /// SUPublicEDKey が実際の鍵らしいか(空・プレースホルダ・文字数違いは不可)。
    nonisolated static func hasValidPublicKey(_ info: [String: Any]?) -> Bool {
        guard let key = (info?["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, !key.contains("PLACEHOLDER"), let data = Data(base64Encoded: key) else { return false }
        return data.count == 32   // Ed25519 の公開鍵は 32 バイト
    }

    #if SPARKLE
    private var controller: SPUStandardUpdaterController?
    #endif

    /// 起動時に 1 回。配布版かつ鍵があるときだけ、自動確認(1 日 1 回)を始める。
    func start() {
        #if SPARKLE
        guard Self.isAvailable, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    func checkForUpdates() {
        #if SPARKLE
        controller?.checkForUpdates(nil)
        #endif
    }
}
