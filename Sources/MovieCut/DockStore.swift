import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MovieCutCore

/// 画面のドッキング(パネルの配置)の持ち主。アプリ全体で 1 つ(ドキュメントごとではない)。
/// 変わるたびに UserDefaults へ書き(`defaults` が nil のときは書かない)、起動時に読み戻す(壊れていれば初期配置)。
@MainActor
final class DockStore: ObservableObject {
    static let defaultsKey = "dockLayout.v2"

    @Published private(set) var layout: DockLayout
    private let defaults: UserDefaults?
    /// 配置が変わったあと(メニューの ✓ を更新するため)。
    var onChange: (() -> Void)?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        // 起動時は、別ウインドウに出ていたパネルを初期の位置へ戻す
        layout = DockLayout.forLaunch(from: defaults?.data(forKey: Self.defaultsKey))
    }

    /// 配置を書き換える。変わったときだけ公開・保存する(`persist: false` はドラッグ中。終わりで `commit()`)。
    @discardableResult
    func mutate(persist: Bool = true, _ body: (inout DockLayout) -> Bool) -> Bool {
        var l = layout
        guard body(&l), l != layout else { return false }
        guard l.isValid else { return false }   // 不変条件が崩れる操作は採用しない
        layout = l
        if persist { commit() }
        onChange?()
        return true
    }

    func commit() {
        guard let defaults, let d = layout.encoded() else { return }
        defaults.set(d, forKey: Self.defaultsKey)
    }

    // MARK: 操作(DockLayout の同名の操作)

    func setActive(_ p: DockPanel) { mutate { $0.setActive(p) } }
    func moveToTab(_ p: DockPanel, ofGroupContaining t: DockPanel, at i: Int? = nil) { mutate { $0.moveToTab(p, ofGroupContaining: t, at: i) } }
    func moveToEdge(_ p: DockPanel, _ e: DockEdge, ofGroupContaining t: DockPanel) { mutate { $0.moveToEdge(p, e, ofGroupContaining: t) } }
    func moveToRootEdge(_ p: DockPanel, _ e: DockEdge) { mutate { $0.moveToRootEdge(p, e, fraction: DockDropTarget.outerFraction) } }
    func detach(_ p: DockPanel) { mutate { $0.detach(p) } }
    func attach(_ p: DockPanel) { mutate { $0.attach(p) } }
    func close(_ p: DockPanel) { mutate { $0.close(p) } }
    func toggle(_ p: DockPanel) { mutate { $0.toggle(p); return true } }
    func apply(_ preset: DockPreset) { mutate { $0.apply(preset); return true } }
    func setFraction(at path: [Bool], to v: Double, persist: Bool) { mutate(persist: persist) { $0.setFraction(at: path, to: v) } }
}

/// ドラッグ中のパネル(同じアプリの中のドラッグだけなので、ここに持つ。ドロップ側の受け皿の判定は専用の型で行う)。
@MainActor
enum DockDrag {
    static var current: DockPanel?
    /// ドラッグの入れ物の型(Info.plist の UTExportedTypeDeclarations にも宣言する)。
    static let type = UTType(exportedAs: "jp.local.moviecut.dock-panel", conformingTo: .data)

    static func provider(for panel: DockPanel) -> NSItemProvider {
        current = panel
        let p = NSItemProvider()
        p.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(panel.rawValue.data(using: .utf8), nil)
            return nil
        }
        return p
    }
}
