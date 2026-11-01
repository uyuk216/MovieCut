import Foundation
import MovieCutCore

/// プロキシ編集: 出力 ▸ プロキシを作成(映像の素材ごとに 540p のプロキシを背景で作る。キャンセル可)。
/// 表示 ▸ プロキシで編集 は `ProxySettings`(アプリ全体)。プレビューの読み先だけを変え、書き出しは元の素材を読む。
extension ProjectModel {
    /// プレビューの素材キャッシュに渡す検索(元のパス → 作成済みのプロキシのパス)。
    nonisolated static func previewProxyPath(_ path: String) -> String? {
        ProxyStore.existingProxy(for: URL(fileURLWithPath: path))?.path
    }

    /// 映像クリップの素材(重複なし・並び順固定)。
    var videoSourcePaths: [String] {
        Array(Set(project.allClips.filter { $0.type == .video }.compactMap(\.src))).sorted()
    }

    /// 出力 ▸ プロキシを作成。素材ごとに順に作る(作成済みは飛ばす)。作成中は編集をロックする(書き出しと同じ)。
    func makeProxies() {
        guard !isLocked else { return }
        let paths = videoSourcePaths
        guard !paths.isEmpty else { statusText = "映像の素材がありません"; return }
        busyMessage = "プロキシを作っています 0/\(paths.count)"
        let task = Task { [weak self] () -> Void in
            defer {
                Task { @MainActor [weak self] in
                    self?.proxyCancel = nil
                    self?.busyMessage = nil
                    self?.assets.setPreviewProxies(ProxySettings.enabled(), lookup: ProjectModel.previewProxyPath)
                }
            }
            for (i, p) in paths.enumerated() {
                try Task.checkCancellation()
                let n = i + 1
                _ = try await ProxyStore.make(source: URL(fileURLWithPath: p), progress: { v in
                    Task { @MainActor in self?.busyMessage = "プロキシを作っています \(n)/\(paths.count) (\(Int(v * 100))%)" }
                })
            }
        }
        proxyCancel = { task.cancel() }
        Task { [weak self] in
            do {
                try await task.value
                self?.statusText = "プロキシを \(paths.count) 件作りました"
            } catch is CancellationError {
                self?.statusText = "プロキシの作成を止めました"
            } catch let e as ProxyError where e == .cancelled {
                self?.statusText = "プロキシの作成を止めました"
            } catch {
                self?.errorTitle = "プロキシを作れませんでした"
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
