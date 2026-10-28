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

/// 書類ウインドウの本体: 配置の木(分割とタブのグループ)を描く。
struct DockHost: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var store: DockStore

    var body: some View {
        if let root = store.layout.root {
            DockNodeView(node: root, path: [], model: model, store: store)
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
    @State private var zone: DockDropZone?
    static let tabBarHeight = 26.0

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                DockTabBar(group: group, store: store)
                Divider()
                DockPanelContent(panel: group.active, model: model)
            }
            .overlay { DockDropHighlight(zone: zone, tabBarHeight: Self.tabBarHeight) }
            .onDrop(of: [DockDrag.type], delegate: DockGroupDropDelegate(anchor: group.active, size: geo.size, zone: $zone, store: store))
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

/// ドロップ位置のハイライト(タブとして合流 = 全体、端 = その側の半分)。
struct DockDropHighlight: View {
    let zone: DockDropZone?
    let tabBarHeight: Double

    var body: some View {
        GeometryReader { geo in
            if let zone {
                let w = geo.size.width, h = geo.size.height
                let r: CGRect = {
                    switch zone {
                    case .tab: return CGRect(x: 0, y: 0, width: w, height: h)
                    case .edge(.left): return CGRect(x: 0, y: tabBarHeight, width: w / 2, height: h - tabBarHeight)
                    case .edge(.right): return CGRect(x: w / 2, y: tabBarHeight, width: w / 2, height: h - tabBarHeight)
                    case .edge(.top): return CGRect(x: 0, y: tabBarHeight, width: w, height: (h - tabBarHeight) / 2)
                    case .edge(.bottom): return CGRect(x: 0, y: tabBarHeight + (h - tabBarHeight) / 2, width: w, height: (h - tabBarHeight) / 2)
                    }
                }()
                Rectangle().fill(Color.accentColor.opacity(0.28))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .allowsHitTesting(false)
    }
}

/// グループ全体のドロップ先: 位置でタブ合流 / 辺への分割を決める。
struct DockGroupDropDelegate: DropDelegate {
    let anchor: DockPanel
    let size: CGSize
    @Binding var zone: DockDropZone?
    let store: DockStore

    private func zone(at p: CGPoint) -> DockDropZone {
        DockDropZone.zone(x: Double(p.x), y: Double(p.y), width: Double(size.width), height: Double(size.height), tabBarHeight: DockGroupView.tabBarHeight)
    }

    func validateDrop(info: DropInfo) -> Bool { DockDrag.current != nil }
    func dropEntered(info: DropInfo) { zone = zone(at: info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? { zone = zone(at: info.location); return DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { zone = nil; DockDrag.current = nil }
        guard let dragged = DockDrag.current else { return false }
        switch zone(at: info.location) {
        case .tab: store.moveToTab(dragged, ofGroupContaining: anchor)
        case .edge(let e): store.moveToEdge(dragged, e, ofGroupContaining: anchor)
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
