import AppKit
import MovieCutCore

/// ファイルパネル(NSOpenPanel / NSSavePanel)の提示を一手に引き受ける。
/// - 同時に 1 枚しか出さない(PanelPresentationGate)。
/// - 非同期提示は必ずホストウィンドウへのシートにする(浮動パネルは何もブロックせず重なるため禁止)。
/// - テスト/検証文脈ではパネルを一切出さない。
@MainActor
final class FilePanelPresenter {
    static let shared = FilePanelPresenter()
    private let gate = PanelPresentationGate()

    /// テスト/検証文脈ではパネルを一切出さない
    nonisolated static var isEnvironmentSuppressed: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || DebugHooks.isQuiet
    }

    /// 非同期提示。必ずホストウィンドウへのシートにする(浮動パネル禁止)。
    /// 提示できない場合(環境抑止・ウィンドウなし・提示中)は completion(.cancel) をメインキューで非同期に返す。
    func present(_ panel: NSSavePanel, window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let host = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard PanelPresentationGate.shouldPresent(userInitiated: true, hasHostWindow: host != nil,
                                                  alreadyPresenting: gate.isPresenting,
                                                  environmentSuppressed: Self.isEnvironmentSuppressed),
              let host, let token = gate.tryAcquire() else {
            DispatchQueue.main.async { completion(.cancel) }
            return
        }
        panel.beginSheetModal(for: host) { [gate] resp in
            gate.release(token)
            completion(resp)
        }
    }

    /// 同期モーダル提示(従来 panel.runModal() だった箇所用)。提示できない場合は .cancel を即返す(ブロックしない)。
    func runModal(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        guard !Self.isEnvironmentSuppressed, let token = gate.tryAcquire() else { return .cancel }
        defer { gate.release(token) }
        return panel.runModal()
    }
}
