import SwiftUI
import MovieCutCore

/// 書き出しキューの App 側の入れ物。並び・実行・状態は Core の `ExportQueue` が決め、ここは実際の書き出し(runner)をつなぐだけ。
/// 投入時にプロジェクトの写し(値)を受け取るので、あとで編集しても、待っている件の中身は変わらない。
@MainActor
final class ExportQueueController: ObservableObject {
    /// 1 件の書き出し。テストでは偽物に差し替える。
    typealias Runner = (_ project: Project, _ range: ExportRange?, _ url: URL, _ progress: @escaping (Double) -> Void) async throws -> Void

    let queue = ExportQueue()
    private let runner: Runner
    /// Dock の進行バーの差し替え(テスト用。通常は `AppServices.dock`)。
    private let dockOverride: DockProgressController?
    /// 件の ID → 保存先のパス(一覧の表示用)。
    private var destinations: [UUID: String] = [:]

    init(runner: Runner? = nil, dock: DockProgressController? = nil) {
        self.runner = runner ?? ExportQueueController.defaultRunner
        self.dockOverride = dock
        queue.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    /// 1 件を書く間の画面の決まり(直接の書き出しと同じ): Dock の進行バー、ファン最大化、終わりの知らせ。
    /// 終わったあとに遅れて届いた進み具合では Dock を出し直さない。
    static func withExportHooks(dock: DockProgressController, progress: @escaping (Double) -> Void,
                                _ body: (@escaping (Double) -> Void) async throws -> Void) async throws {
        final class Live { var on = true }
        let live = Live()
        let report: (Double) -> Void = { v in
            progress(v)
            Task { @MainActor in
                guard live.on else { return }
                dock.update(v)
            }
        }
        dock.update(0)
        await AppServices.fan.beginExport()
        do {
            try await body(report)
        } catch is CancellationError {
            live.on = false
            await AppServices.fan.endExport(.cancelled)
            dock.finish(notify: false)
            throw CancellationError()
        } catch {
            live.on = false
            await AppServices.fan.endExport(.failed)
            dock.finish(notify: true)
            throw error
        }
        live.on = false
        await AppServices.fan.endExport(.finished)
        dock.finish(notify: true)
    }

    /// 本番の書き出し: MP4(今の設定のまま)。描画は書き出しと同じ経路。
    static let defaultRunner: Runner = { project, range, url, progress in
        try await ExportJob.run(project: project, preset: nil, range: range, to: url, progress: progress)
    }

    var entries: [ExportQueue.Entry] { queue.entries }

    /// 件の保存先(パス)。知らない ID は nil。
    func destination(of id: UUID) -> String? { destinations[id] }

    /// 件を末尾に積む。`project` は値の写しとして受け取る(投入後の編集は影響しない)。
    @discardableResult
    func enqueue(project: Project, range: ExportRange?, to url: URL) -> UUID {
        let run = runner
        let dock = dockOverride ?? AppServices.dock
        let id = queue.enqueue(title: url.lastPathComponent) { progress in
            try await Self.withExportHooks(dock: dock, progress: progress) { report in
                try await run(project, range, url, report)
            }
        }
        destinations[id] = url.path
        return id
    }

    /// 待っている件は取り消し、実行中の件はキャンセルを頼む。
    func cancel(_ id: UUID) { queue.cancel(id) }

    /// 終わった件を一覧から外す。待っている件と実行中の件は残す。
    func clearFinished() {
        queue.clearFinished()
        destinations = destinations.filter { queue.state(of: $0.key) != nil }
    }
}

/// 出力 ▸ 書き出しキューを表示…。件ごとの状態・進み具合・取り消し。
struct ExportQueueSheet: View {
    @ObservedObject var controller: ExportQueueController
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("書き出しキュー").font(.title3.bold())
            if controller.entries.isEmpty {
                Text("キューは空です。出力 ▸ 書き出しキューに追加… で、今の設定の MP4 を積めます。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            } else {
                List(controller.entries) { e in row(e) }
                    .frame(minHeight: 200)
                    .accessibilityIdentifier("export-queue-list")
            }
            HStack {
                Button("終わったものを消す") { controller.clearFinished() }
                    .disabled(!controller.entries.contains { !$0.state.isActive })
                Spacer()
                Button("閉じる", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    @ViewBuilder
    private func row(_ e: ExportQueue.Entry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title).lineLimit(1).truncationMode(.middle)
                if let dest = controller.destination(of: e.id) {
                    Text(dest).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
                Text(Self.statusText(e.state)).font(.caption).foregroundStyle(.secondary)
                if case .running(let v) = e.state {
                    ProgressView(value: v).frame(width: 300)
                }
            }
            Spacer(minLength: 8)
            if e.state.isActive {
                Button("取り消す") { controller.cancel(e.id) }
                    .controlSize(.small)
            }
        }
        .accessibilityIdentifier("export-queue-row")
    }

    /// 状態の文言(テストから見えるよう static)。
    static func statusText(_ s: ExportQueue.State) -> String {
        switch s {
        case .waiting: return "待機中"
        case .running(let v): return "書き出し中 \(Int((v * 100).rounded()))%"
        case .finished: return "完了"
        case .cancelled: return "取り消し"
        case .failed(let m): return "失敗: \(m)"
        }
    }
}
