import Foundation
import MovieCutCore

/// 保存した文字スタイル(アプリ全体。UserDefaults に JSON で保存、プロジェクトファイルには入れない)。
/// 組み込みの 6 つは別に持つ(`TextStyleLibrary.builtins`)。静かな検証(MC_DEBUG_*)では UserDefaults に書かない。
@MainActor
final class TextStyleStore: ObservableObject {
    static let shared = TextStyleStore(defaults: DebugHooks.isQuiet ? nil : DataLocations.current.defaults)

    @Published private(set) var user: [SavedTextStyle]
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        user = defaults.map { TextStyleLibrary.loadUser(from: $0) } ?? []
    }

    var all: [SavedTextStyle] { TextStyleLibrary.all(user: user) }
    func find(_ id: String) -> SavedTextStyle? { TextStyleLibrary.find(id, user: user) }

    private func persist() { if let d = defaults { TextStyleLibrary.saveUser(user, to: d) } }

    /// 見た目を名前をつけて保存する。足した id(名前が空・上限なら nil)。
    @discardableResult
    func add(name: String, look: TextLook) -> String? {
        var list = user
        guard let id = TextStyleLibrary.add(&list, name: name, look: look) else { return nil }
        user = list; persist()
        return id
    }

    @discardableResult
    func rename(id: String, to name: String) -> Bool {
        var list = user
        guard TextStyleLibrary.rename(&list, id: id, to: name) else { return false }
        user = list; persist()
        return true
    }

    @discardableResult
    func delete(id: String) -> Bool {
        var list = user
        guard TextStyleLibrary.delete(&list, id: id) else { return false }
        user = list; persist()
        return true
    }
}
