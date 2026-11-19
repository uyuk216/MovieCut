import Foundation
import MovieCutCore

/// プロキシ編集: 出力 ▸ プロキシを作成(映像の素材ごとに 540p のプロキシを背景で作る。キャンセル可)。
/// 表示 ▸ プロキシで編集 は `ProxySettings`(アプリ全体)。プレビューの読み先だけを変え、書き出しは元の素材を読む。
/// 素材は複合クリップ・シーンの中も含めて書類全体(根)から集める。外部プロキシの関連付けは書類(`proxyLinks`)に保存する。
extension ProjectModel {
    /// 映像の素材(複合・シーンの中も含む。パス昇順・重複なし)。
    var videoSourcePaths: [String] { ProxySources.videoPaths(in: rootProject) }

    /// プレビューの素材キャッシュに検索を渡す(設定・置き場所が変わったら付け直す)。
    /// 検索は描画のスレッドから呼ばれるので、主スレッドの `rootProject` ではなく、スレッドに安全な写し(`mirror`)を読む。
    func installPreviewProxies() {
        let mirror = self.mirror
        let dir = proxyDirectory
        assets.setPreviewProxies(ProxySettings.enabled()) { path in
            ProxyLinks.resolve(for: path, in: mirror.get(), directory: dir)
        }
    }

    /// 出力 ▸ プロキシを作成。素材ごとに順に作る(作成済みは飛ばす)。作成中は編集をロックする(書き出しと同じ)。
    func makeProxies() {
        let paths = videoSourcePaths
        guard !paths.isEmpty else { statusText = "映像の素材がありません"; return }
        makeProxies(paths: paths)
    }

    /// プロキシを管理シートの「作成」: その 1 件だけ作る(作成済みなら飛ばす)。
    func makeProxy(source: String) {
        makeProxies(paths: [source])
    }

    private func makeProxies(paths: [String]) {
        guard !isLocked else { return }
        busyMessage = "プロキシを作っています 0/\(paths.count)"
        let dir = proxyDirectory
        let task = Task { [weak self] () -> ProxyBatchResult in
            defer {
                Task { @MainActor [weak self] in
                    self?.proxyCancel = nil
                    self?.busyMessage = nil
                    self?.installPreviewProxies()
                }
            }
            // 1 件の失敗で止めず、残りを作る(失敗の数は結果に入る)
            return try await ProxyStore.makeAll(sources: paths.map { URL(fileURLWithPath: $0) }, directory: dir, progress: { n, total, v in
                Task { @MainActor in self?.busyMessage = "プロキシを作っています \(n)/\(total) (\(Int(v * 100))%)" }
            })
        }
        proxyCancel = { task.cancel() }
        Task { [weak self] in
            do {
                let r = try await task.value
                self?.statusText = r.failed.isEmpty
                    ? "プロキシを \(r.made.count) 件作りました"
                    : "プロキシを \(r.made.count) 件作りました(\(r.failed.count) 件は作れませんでした)"
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

    /// 取り込み時の自動作成(設定がオンのときだけ)。編集はロックしない。背景で、表示の短辺が 540 を超える映像だけ作る。
    /// 失敗は数えるだけで騒がない。1 件でも作れたら、プレビューへ付け直して件数を知らせる。
    func autoCreateProxiesIfNeeded(forVideoPaths paths: [String]) {
        guard ProxySettings.autoCreateEnabled(), !paths.isEmpty else { return }
        let dir = proxyDirectory
        let job = Task.detached(priority: .utility) { () -> Int in
            var made = 0
            for path in paths {
                let url = URL(fileURLWithPath: path)
                let size = await ProxyStore.displayedSize(source: url)
                let decision = ProxyAutoCreate.decide(
                    enabled: true, isVideo: true,
                    hasExistingProxy: ProxyStore.existingProxy(for: url, directory: dir) != nil,
                    displayedShortSide: size.map { min($0.width, $0.height) })
                guard decision == .create else { continue }
                if (try? await ProxyStore.make(source: url, directory: dir)) != nil { made += 1 }
            }
            return made
        }
        Task { [weak self] in
            let made = await job.value
            guard made > 0 else { return }
            self?.installPreviewProxies()
            self?.statusText = "プロキシを自動で \(made) 件作りました"
        }
    }

    /// 書類全体(根)を直す編集。複合・シーンの中に入っていても、根だけが持つ値(`proxyLinks`)を確実に書き換える。
    private func editRoot(_ name: String, _ body: (inout Project) -> Void) -> Bool {
        var root = rootProject
        body(&root)
        guard root != rootProject else { return false }
        applyRoot(root, name: name)
        return true
    }

    /// 素材に外部のプロキシを関連付ける(書類に保存。Undo 1 回)。素材がこの書類の映像でない・空・自分自身なら false。
    @discardableResult
    func attachProxyLink(source: String, proxyPath: String) -> Bool {
        guard !isLocked else { return false }
        let ok = editRoot("プロキシの関連付け") { p in
            if let q = ProxyLinks.attach(to: p, source: source, proxy: proxyPath) { p = q }
        }
        if ok {
            installPreviewProxies()
            statusText = "プロキシを関連付けました"
        } else {
            statusText = "この素材には関連付けられません"
        }
        return ok
    }

    /// 外部プロキシの関連付けを外す(ファイルには触らない)。
    @discardableResult
    func detachProxyLink(source: String) -> Bool {
        guard !isLocked else { return false }
        let ok = editRoot("プロキシの関連付け解除") { p in p = ProxyLinks.detach(from: p, source: source) }
        if ok {
            installPreviewProxies()
            statusText = "プロキシの関連付けを解除しました"
        }
        return ok
    }

    /// 生成済みのプロキシを消す。外部の関連付けのファイルは消さない。
    @discardableResult
    func deleteGeneratedProxy(source: String) -> Bool {
        let ok = ProxyStore.deleteProxy(for: URL(fileURLWithPath: source), directory: proxyDirectory)
        installPreviewProxies()
        statusText = ok ? "生成したプロキシを消しました" : "消すプロキシがありません"
        return ok
    }

    /// この書類の素材の生成済みプロキシを全部消す(外部の関連付けのファイルは消さない)。消せた件数を返す。
    func deleteGeneratedProxiesForProject() -> Int {
        let n = ProxyStore.deleteProxies(for: videoSourcePaths.map { URL(fileURLWithPath: $0) }, directory: proxyDirectory)
        installPreviewProxies()
        statusText = "生成したプロキシを \(n) 件消しました"
        return n
    }

    /// 素材の今のプロキシの状態(外部リンク・生成済み・なし)。
    func proxyStatus(for source: String) -> ProxyStatus {
        ProxyLinks.status(for: source, in: rootProject, directory: proxyDirectory)
    }
}
