import SwiftUI
import AppKit
import MovieCutCore

// MARK: - パネルの中身

/// パネル 1 つぶんの中身(ドッキング中も別ウインドウでも同じもの)。書き出し中などの操作ロックは、これまでと同じくタイムライン以外に効く。
struct DockPanelContent: View {
    let panel: DockPanel
    @ObservedObject var model: ProjectModel

    var body: some View {
        Group {
            switch panel {
            case .characters: LeftPanel(model: model, speakers: AppServices.speakers, scriptText: $model.scriptText).disabled(model.isLocked)
            case .preview: CenterPanel(model: model).disabled(model.isLocked)
            case .inspector: InspectorView(model: model, speakers: AppServices.speakers).disabled(model.isLocked)
            case .timeline: TimelineSection(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 木の描画

/// ドラッグ中のドロップ先の状態(ドック全体の外側の端)。グループの中のハイライトは各グループが持つ。
@MainActor
final class DockDropState: ObservableObject {
    @Published var outer: DockEdge?
    var hostSize: CGSize = .zero
}

private struct DockDropStateKey: EnvironmentKey { static let defaultValue: DockDropState? = nil }
extension EnvironmentValues {
    var dockDropState: DockDropState? {
        get { self[DockDropStateKey.self] }
        set { self[DockDropStateKey.self] = newValue }
    }
}

/// 書類ウインドウの本体: 配置の木(分割とタブのグループ)を描く。
struct DockHost: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var store: DockStore
    @StateObject private var dropState = DockDropState()

    var body: some View {
        if let root = store.layout.root {
            GeometryReader { geo in
                DockNodeView(node: root, path: [], model: model, store: store)
                    .environment(\.dockDropState, dropState)
                    .overlay { DockOuterHighlight(edge: dropState.outer) }
                    .coordinateSpace(name: DockHost.space)
                    .onAppear { dropState.hostSize = geo.size }
                    .onChange(of: geo.size) { _, n in dropState.hostSize = n }
            }
        } else {
            VStack(spacing: 10) {
                Text("パネルがありません").font(.headline)
                Text("別ウインドウに出しているか、閉じています。表示メニューの「パネル」から開けます。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("初期配置に戻す") { store.apply(.initial) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static let space = "dockHost"
}

struct DockNodeView: View {
    let node: DockNode
    let path: [Bool]
    @ObservedObject var model: ProjectModel
    @ObservedObject var store: DockStore

    var body: some View {
        switch node {
        case .group(let g):
            DockGroupView(group: g, model: model, store: store)
        case .split(let axis, let fraction, let first, let second):
            DockSplitView(axis: axis, fraction: fraction, first: first, second: second, path: path, model: model, store: store)
        }
    }
}

struct DockSplitView: View {
    let axis: DockAxis
    let fraction: Double
    let first: DockNode
    let second: DockNode
    let path: [Bool]
    @ObservedObject var model: ProjectModel
    @ObservedObject var store: DockStore
    @State private var dragStartSize: Double?

    var body: some View {
        GeometryReader { geo in
            let horizontal = axis == .horizontal
            let total = Double(horizontal ? geo.size.width : geo.size.height)
            let firstSize = CGFloat(DockMetrics.firstSize(total: total, fraction: fraction))
            let stack = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                DockNodeView(node: first, path: path + [false], model: model, store: store)
                    .frame(width: horizontal ? firstSize : nil, height: horizontal ? nil : firstSize)
                    .clipped()
                divider(total: total, currentFirst: Double(firstSize))
                DockNodeView(node: second, path: path + [true], model: model, store: store)
                    .clipped()
            }
        }
    }

    /// 仕切り(1pt の線 + つかみやすい幅)。ドラッグ中は保存せず、離したときに保存する。
    private func divider(total: Double, currentFirst: Double) -> some View {
        let horizontal = axis == .horizontal
        let t = CGFloat(DockMetrics.dividerThickness)
        return ZStack {
            Color(nsColor: .underPageBackgroundColor).opacity(0.5)
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
        }
        .frame(width: horizontal ? t : nil, height: horizontal ? nil : t)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { v in
                    let start = dragStartSize ?? currentFirst
                    dragStartSize = start
                    let delta = Double(horizontal ? v.translation.width : v.translation.height)
                    let size = min(max(start + delta, DockMetrics.minPanelSize), max(total - DockMetrics.dividerThickness - DockMetrics.minPanelSize, DockMetrics.minPanelSize))
                    store.setFraction(at: path, to: DockMetrics.fraction(forFirstSize: size, total: total), persist: false)
                }
                .onEnded { _ in dragStartSize = nil; store.commit() }
        )
    }
}

// MARK: - タブのグループ

struct DockGroupView: View {
    let group: DockGroup
    @ObservedObject var model: ProjectModel
    @ObservedObject var store: DockStore
    @Environment(\.dockDropState) private var dropState
    @State private var zone: DockDropTarget?
    static let tabBarHeight = 26.0

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .named(DockHost.space)).origin
            VStack(spacing: 0) {
                DockTabBar(group: group, store: store)
                Divider()
                DockPanelContent(panel: group.active, model: model)
            }
            .overlay { DockDropHighlight(zone: zone, tabBarHeight: Self.tabBarHeight) }
            .onDrop(of: [DockDrag.type], delegate: DockGroupDropDelegate(anchor: group.active, size: geo.size, origin: origin, zone: $zone, state: dropState, store: store))
        }
    }
}

struct DockTabBar: View {
    let group: DockGroup
    @ObservedObject var store: DockStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(group.panels.enumerated()), id: \.element) { i, p in
                DockTab(panel: p, index: i, active: p == group.active, group: group, store: store)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: DockGroupView.tabBarHeight)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
    }
}

struct DockTab: View {
    let panel: DockPanel
    let index: Int
    let active: Bool
    let group: DockGroup
    @ObservedObject var store: DockStore

    var body: some View {
        Text(panel.title)
            .font(.system(size: 12, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(active ? Color.accentColor.opacity(0.35) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture { store.setActive(panel) }
            .onDrag { DockDrag.provider(for: panel) }
            // タブの上にドロップ → この位置に差し込む(同じグループなら並べ替え)
            .onDrop(of: [DockDrag.type], delegate: DockTabDropDelegate(panel: panel, index: index, store: store))
            .contextMenu {
                Button("別ウインドウで開く") { store.detach(panel) }
                Button("閉じる") { store.close(panel) }
            }
            .help("\(panel.title)(ドラッグして他のグループへ。右クリックで別ウインドウ / 閉じる)")
    }
}

// MARK: - ドロップ

/// ドロップ先の説明(ハイライトの中に出す)。
extension DockDropTarget {
    var label: String {
        func side(_ e: DockEdge) -> String { switch e { case .left: return "左"; case .right: return "右"; case .top: return "上"; case .bottom: return "下" } }
        switch self {
        case .tab: return "タブとして追加"
        case .edge(let e): return "\(side(e))に分割"
        case .outer(let e): return "ウインドウの\(side(e))端に置く"
        }
    }
}

/// ドロップ位置のハイライト。5 つの領域(中央 = タブ追加、上下左右 = その側に分割)のうち、ポインタの下の領域を半透明のアクセント色で塗り、
/// パネルが着地する場所を示す。中央の領域の境目は点線で常に見せる。
struct DockDropHighlight: View {
    let zone: DockDropTarget?
    let tabBarHeight: Double
    var edgeRatio = 0.25

    var body: some View {
        GeometryReader { geo in
            if let zone {
                let w = geo.size.width, h = geo.size.height
                let r = zone.highlightRect(width: w, height: h, tabBarHeight: tabBarHeight)
                // 中央(タブ追加)の領域の目印
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: w * (1 - 2 * edgeRatio), height: (h - tabBarHeight) * (1 - 2 * edgeRatio))
                    .position(x: w / 2, y: tabBarHeight + (h - tabBarHeight) / 2)
                ZStack {
                    Rectangle().fill(Color.accentColor.opacity(0.30))
                    Rectangle().stroke(Color.accentColor, lineWidth: 2)
                    Text(zone.label)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                }
                .frame(width: r.width, height: r.height)
                .position(x: r.x + r.width / 2, y: r.y + r.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// ドック全体の外側の端に置くときのハイライト。
struct DockOuterHighlight: View {
    let edge: DockEdge?

    var body: some View {
        GeometryReader { geo in
            if let edge {
                let t = DockDropTarget.outer(edge)
                let r = t.highlightRect(width: geo.size.width, height: geo.size.height)
                ZStack {
                    Rectangle().fill(Color.accentColor.opacity(0.30))
                    Rectangle().stroke(Color.accentColor, lineWidth: 3)
                    Text(t.label)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.65)))
                }
                .frame(width: r.width, height: r.height)
                .position(x: r.x + r.width / 2, y: r.y + r.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

/// グループ全体のドロップ先: 位置でタブ合流 / 辺への分割 / ドック全体の外側の端を決める。ポインタに合わせてハイライトを更新し、出たら消す。
struct DockGroupDropDelegate: DropDelegate {
    let anchor: DockPanel
    let size: CGSize
    /// ドック全体の中でのこのグループの左上。
    let origin: CGPoint
    @Binding var zone: DockDropTarget?
    let state: DockDropState?
    let store: DockStore

    private func target(at p: CGPoint) -> DockDropTarget {
        let host = state?.hostSize ?? .zero
        return DockDropTarget.resolve(x: Double(p.x), y: Double(p.y), width: Double(size.width), height: Double(size.height),
                                      groupX: Double(origin.x), groupY: Double(origin.y), hostWidth: Double(host.width), hostHeight: Double(host.height),
                                      tabBarHeight: DockGroupView.tabBarHeight)
    }

    private func show(_ t: DockDropTarget?) {
        if case .outer(let e)? = t { state?.outer = e; zone = nil } else { state?.outer = nil; zone = t }
    }

    func validateDrop(info: DropInfo) -> Bool { DockDrag.current != nil }
    func dropEntered(info: DropInfo) { show(target(at: info.location)) }
    func dropUpdated(info: DropInfo) -> DropProposal? { show(target(at: info.location)); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { show(nil) }

    func performDrop(info: DropInfo) -> Bool {
        let t = target(at: info.location)
        defer { show(nil); DockDrag.current = nil }
        guard let dragged = DockDrag.current else { return false }
        switch t {
        case .tab: store.moveToTab(dragged, ofGroupContaining: anchor)
        case .edge(let e): store.moveToEdge(dragged, e, ofGroupContaining: anchor)
        case .outer(let e): store.moveToRootEdge(dragged, e)
        }
        return true
    }
}

/// タブ 1 つのドロップ先: その位置へ差し込む。
struct DockTabDropDelegate: DropDelegate {
    let panel: DockPanel
    let index: Int
    let store: DockStore

    func validateDrop(info: DropInfo) -> Bool { DockDrag.current != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer { DockDrag.current = nil }
        guard let dragged = DockDrag.current, dragged != panel else { return false }
        store.moveToTab(dragged, ofGroupContaining: panel, at: index)
        return true
    }
}
