import Foundation

// MARK: - VST3 純正 GUI(エディタ)のライフサイクル管理(R5 キュー3)
//
// `VST3HostProcessor` の作法に倣う: 失敗しても例外は投げず、状態と理由を保持する。
// Core は GUI ライブラリ(AppKit 等)を一切使わない。親ビュー/生成ビューは
// 不透明な UInt64 として扱い、実ウィンドウの生成は App 側(VST3Panel.swift)の責務。
//
// 呼び出し順の契約(テストで固定):
//   open:  handshake → openBundle → createProcessor → setEditorResizeCallback
//          → createEditorView(parent) → getEditorSize
//   close: (view があれば) destroyEditorView → dispose
// 失敗時は、その時点までに作ったものを逆順で全部畳んでから失敗を返す。

/// エディタセッションの失敗理由。
public enum VST3EditorSessionError: Equatable, Sendable {
    /// プラグインがエディタを持たない(エラーと区別する専用)。
    case noEditor
    /// ブリッジが失敗を返した。
    case bridgeFailure(VST3BridgeStatus)
    /// 呼び出し順序の違反(バックエンドは呼ばない)。
    case wrongState
    /// 0 以下のサイズ(バックエンドは呼ばない)。
    case invalidSize
}

public final class VST3EditorSession {
    public enum State: String, Equatable, Sendable { case closed, opened, viewCreated }

    public private(set) var state: State = .closed
    public private(set) var viewHandle: UInt64?
    public private(set) var currentSize: VST3EditorSize?
    public private(set) var lastError: VST3EditorSessionError?
    /// プラグイン → ホストのリサイズ要求。受理するなら true。nil の間は拒否する。
    public var onResizeRequested: ((VST3EditorSize) -> Bool)?

    private let backend: any VST3BridgeBackend
    private let bundlePath: String
    private let cid: String?

    public init(backend: any VST3BridgeBackend, bundlePath: String, cid: String? = nil) {
        self.backend = backend
        self.bundlePath = bundlePath
        self.cid = cid
    }

    deinit { close() }

    /// エディタを開く。成功すると取得したサイズを返す。
    @discardableResult
    public func open(parentHandle: UInt64) -> Result<VST3EditorSize, VST3EditorSessionError> {
        guard state == .closed else { return fail(.wrongState, keepOpen: true) }

        // 1. 版数照合
        let hs = backend.handshake()
        guard hs.status == .ok else { return fail(.bridgeFailure(hs.status)) }
        guard hs.version == VST3Bridge.protocolVersion else { return fail(.bridgeFailure(.resultFalse)) }

        // 2. バンドルを開く(ここまでは畳む対象なし)
        let opened = backend.openBundle(path: bundlePath)
        guard opened == .ok else { return fail(.bridgeFailure(opened)) }
        state = .opened

        // 3. プロセッサ(コントローラ)生成
        let created = backend.createProcessor(cid: cid)
        guard created == .ok else { return fail(.bridgeFailure(created), dispose: true) }

        // 4. プラグインからのリサイズ要求の橋渡し(view 生成より前に登録する)
        let registered = backend.setEditorResizeCallback { [weak self] size in
            guard let self, let handler = self.onResizeRequested else { return false }
            let accepted = handler(size)
            if accepted { self.currentSize = size }
            return accepted
        }
        guard registered == .ok else { return fail(.bridgeFailure(registered), dispose: true) }

        // 5. ビュー生成(エディタ無しは専用エラー)
        let view = backend.createEditorView(parentHandle: parentHandle)
        guard view.status == .ok else {
            let error: VST3EditorSessionError = view.status == .noEditor ? .noEditor : .bridgeFailure(view.status)
            return fail(error, dispose: true)
        }
        viewHandle = view.viewHandle

        // 6. サイズ交渉の初回取得
        let got = backend.getEditorSize()
        guard got.status == .ok, let size = got.size else {
            return fail(.bridgeFailure(got.status == .ok ? .internalError : got.status), destroyView: true, dispose: true)
        }
        currentSize = size
        state = .viewCreated
        lastError = nil
        return .success(size)
    }

    /// ホスト側のウィンドウサイズ変更を伝える。成功時はプラグインが確定したサイズを返す。
    @discardableResult
    public func resize(to size: VST3EditorSize) -> Result<VST3EditorSize, VST3EditorSessionError> {
        guard state == .viewCreated else { return reject(.wrongState) }
        guard size.isValid else { return reject(.invalidSize) }
        let set = backend.setEditorSize(size)
        guard set == .ok else { return reject(.bridgeFailure(set)) }
        // プラグインが別サイズへ丸めた場合に追従するため、確定サイズを再取得する
        let got = backend.getEditorSize()
        guard got.status == .ok, let confirmed = got.size else {
            return reject(.bridgeFailure(got.status == .ok ? .internalError : got.status))
        }
        currentSize = confirmed
        lastError = nil
        return .success(confirmed)
    }

    /// 閉じる(冪等)。view があれば destroyEditorView → dispose の順。
    public func close() {
        guard state != .closed else { return }
        teardown(destroyView: state == .viewCreated)
    }

    // MARK: 内部

    /// 開いた分を畳んで closed に戻す。
    private func teardown(destroyView: Bool) {
        if destroyView { _ = backend.destroyEditorView() }
        backend.dispose()
        state = .closed
        viewHandle = nil
        currentSize = nil
    }

    /// open の失敗: 必要な分を畳んで失敗を返す。`keepOpen` は既に開いている状態への二重 open 用(何も触らない)。
    private func fail(_ error: VST3EditorSessionError, keepOpen: Bool = false,
                      destroyView: Bool = false, dispose: Bool = false) -> Result<VST3EditorSize, VST3EditorSessionError> {
        if !keepOpen {
            if destroyView { _ = backend.destroyEditorView() }
            if dispose || destroyView { backend.dispose() }
            state = .closed
            viewHandle = nil
            currentSize = nil
        }
        lastError = error
        return .failure(error)
    }

    /// resize の失敗(状態は変えない)。
    private func reject(_ error: VST3EditorSessionError) -> Result<VST3EditorSize, VST3EditorSessionError> {
        lastError = error
        return .failure(error)
    }
}
