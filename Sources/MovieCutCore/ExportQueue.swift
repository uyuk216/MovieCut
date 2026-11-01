import Foundation

// MARK: - 書き出しキュー

/// 書き出し 1 件の中身。進み具合(0〜1)を `progress` に渡し、キャンセルされたら CancellationError を投げる。
public typealias ExportWork = (_ progress: @escaping (Double) -> Void) async throws -> Void

/// 書き出しキュー: 書き出し要求を先着順に 1 件ずつ実行する(並列にはしない。書き出しは重く、ファイルの取り合いになるため)。
/// 待っている件は取り消すと実行されず、実行中の件はキャンセルすると途中のファイルを作った側が消す。
/// UI(状態の一覧シート)は `entries` と `onChange` を読むだけ。実行の順番と状態の遷移はここで決める。
@MainActor
public final class ExportQueue {
    public enum State: Equatable {
        case waiting
        case running(Double)
        case finished
        case cancelled
        case failed(String)

        /// 待っている・実行中(まだ終わっていない)。
        public var isActive: Bool {
            switch self {
            case .waiting, .running: return true
            case .finished, .cancelled, .failed: return false
            }
        }
    }

    public struct Entry: Identifiable, Equatable {
        public let id: UUID
        public let title: String
        public var state: State
    }

    /// 投入された順の一覧(終わったものも残る。`clearFinished()` で消す)。
    public private(set) var entries: [Entry] = []

    /// 一覧が変わるたびに呼ばれる(シートの更新用)。
    public var onChange: (() -> Void)?

    private var works: [UUID: ExportWork] = [:]
    private var running: (id: UUID, task: Task<Void, Never>)?

    public init() {}

    /// 実行中の件があるか。
    public var isBusy: Bool { running != nil }

    /// 件を末尾に積む。空いていれば、すぐ実行を始める。返り値はその件の ID。
    @discardableResult
    public func enqueue(title: String, _ work: @escaping ExportWork) -> UUID {
        let id = UUID()
        entries.append(Entry(id: id, title: title, state: .waiting))
        works[id] = work
        changed()
        pump()
        return id
    }

    /// 待っている件は実行せずに「取り消し」にする。実行中の件はキャンセルを頼み、終わったら「取り消し」になる。
    /// 終わった件・知らない ID は何もしない。
    public func cancel(_ id: UUID) {
        guard let e = entries.first(where: { $0.id == id }) else { return }
        switch e.state {
        case .waiting:
            works[id] = nil
            set(id, .cancelled)
            changed()
        case .running:
            if running?.id == id { running?.task.cancel() }
        case .finished, .cancelled, .failed:
            break
        }
    }

    /// 待っている件と実行中の件をすべて取り消す。
    public func cancelAll() {
        for e in entries where e.state.isActive { cancel(e.id) }
    }

    /// 終わった件(完了・取り消し・失敗)を一覧から外す。待っている件と実行中の件は残す。
    public func clearFinished() {
        let before = entries.count
        entries.removeAll { !$0.state.isActive }
        if entries.count != before { changed() }
    }

    /// 件の状態。知らない ID は nil。
    public func state(of id: UUID) -> State? { entries.first { $0.id == id }?.state }

    // MARK: 内部

    private func pump() {
        guard running == nil, let next = entries.first(where: { $0.state == .waiting }), let work = works.removeValue(forKey: next.id) else { return }
        let id = next.id
        set(id, .running(0))
        changed()
        let task = Task { @MainActor [weak self] in
            do {
                try await work { v in
                    Task { @MainActor [weak self] in self?.progress(id, v) }
                }
                self?.end(id, .finished)
            } catch is CancellationError {
                self?.end(id, .cancelled)
            } catch {
                self?.end(id, .failed(error.localizedDescription))
            }
        }
        running = (id, task)
    }

    private func end(_ id: UUID, _ s: State) {
        set(id, s)
        running = nil
        changed()
        pump()
    }

    private func progress(_ id: UUID, _ v: Double) {
        // 終わった後に遅れて届いた進み具合は無視する
        guard let e = entries.first(where: { $0.id == id }), case .running = e.state else { return }
        set(id, .running(min(1, max(0, v))))
        changed()
    }

    private func set(_ id: UUID, _ s: State) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = s
    }

    private func changed() { onChange?() }
}
