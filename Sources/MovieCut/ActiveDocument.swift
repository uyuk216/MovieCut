import SwiftUI
import Combine

/// いま前面のドキュメント(ProjectModel)と、メニューの有効・チェックに効く状態。
/// メニューバーはこれを見て、前面のドキュメントだけを操作する。
/// (SwiftUI の @FocusedObject は、入力欄などにフォーカスが無いと nil になるので使わない。)
@MainActor
final class ActiveDocument: ObservableObject {
    static let shared = ActiveDocument()

    private(set) var model: ProjectModel?
    /// メニューが読む状態。変わったときだけ発行する(再生中に毎フレーム再描画しないため)。
    @Published private(set) var state = MenuState()
    private var cancellable: AnyCancellable?

    init() {}

    /// このドキュメントのウィンドウが前面(メイン)になった。
    func activate(_ m: ProjectModel) {
        guard model !== m else { refresh(); return }
        model = m
        cancellable = m.objectWillChange.sink { [weak self] _ in
            // 変更が済んでから読む
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh()
    }

    /// このドキュメントが閉じられた(前面だったら外す)。
    func deactivate(_ m: ProjectModel) {
        guard model === m else { return }
        model = nil
        cancellable = nil
        refresh()
    }

    func refresh() {
        let s = MenuState(model: model)
        if s != state { state = s }
    }
}
