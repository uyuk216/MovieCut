import Foundation

/// 全キャッシュが経由する単一の予算管理。
///
/// - エントリはバイトコスト付きで登録する。
/// - 合計が上限を超えたら LRU(最も長く使われていないもの)順に破棄する。
/// - 破棄の実体解放は登録時のクロージャ(`onEvict`)に任せる。このクラス自体は
///   キャッシュの中身を持たないので、画像・音声など種類を問わず使える。
/// - **ディスクへの書き出しは一切しない**(ファイル書き込み API を使わない)。
/// - 上限なし(`limitBytes == nil`)の場合は破棄しない。
/// - スレッドセーフ: 全ての公開 API は内部ロックで直列化される。
///   `onEvict` はロックの外で呼ばれる(クロージャ内から再入してもデッドロックしない)。
public final class CacheBudgetManager: @unchecked Sendable {
    public typealias EvictHandler = () -> Void

    private struct Entry {
        var cost: Int64
        var onEvict: EvictHandler
    }

    private let lock = NSLock()
    /// 上限(バイト)。nil は上限なし。
    public let limitBytes: Int64?
    private var entries: [String: Entry] = [:]
    /// LRU 順序: 先頭が最も古い(次に破棄される候補)、末尾が最も新しい。
    private var order: [String] = []
    private var total: Int64 = 0

    public init(limitBytes: Int64?) {
        self.limitBytes = limitBytes.map { max(0, $0) }
    }

    /// MemoryBudget から作る便利イニシャライザ。
    public convenience init(totalRAMBytes: Int64, platform: MemoryBudgetPlatform = .mac) {
        self.init(limitBytes: MemoryBudget.limitBytes(totalRAMBytes: totalRAMBytes, platform: platform))
    }

    // MARK: - 状態

    public var totalBytes: Int64 { lock.lock(); defer { lock.unlock() }; return total }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public var isUnlimited: Bool { limitBytes == nil }
    /// LRU 順(古い順)のキー一覧。テスト・診断用。
    public var keysInLRUOrder: [String] { lock.lock(); defer { lock.unlock() }; return order }
    public func contains(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return entries[key] != nil }
    public func cost(of key: String) -> Int64? { lock.lock(); defer { lock.unlock() }; return entries[key]?.cost }

    // MARK: - 登録・利用・削除

    /// エントリを登録する。同じキーがあれば差し替え(古い方の `onEvict` は呼ばない)、MRU になる。
    /// 登録後に合計が上限を超えていれば、LRU 順に破棄して上限以下に戻す。
    /// 1 件だけで上限を超える場合は、そのエントリ自体も破棄される(上限を絶対に超えない)。
    /// - Returns: 破棄されたキーの一覧(LRU 順)。
    @discardableResult
    public func register(key: String, cost: Int64, onEvict: @escaping EvictHandler) -> [String] {
        let safeCost = max(0, cost)
        var evicted: [(String, EvictHandler)] = []
        lock.lock()
        if let old = entries[key] {
            total -= old.cost
            order.removeAll { $0 == key }
        }
        entries[key] = Entry(cost: safeCost, onEvict: onEvict)
        order.append(key)
        total += safeCost
        evicted = collectEvictionsLocked()
        lock.unlock()
        for (_, handler) in evicted { handler() }
        return evicted.map { $0.0 }
    }

    /// 使ったことを知らせる(MRU へ移動)。無いキーは無視。
    public func touch(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        guard entries[key] != nil else { return }
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// エントリを取り除く。`callEvict` が true なら実体解放クロージャも呼ぶ。
    @discardableResult
    public func remove(_ key: String, callEvict: Bool = true) -> Bool {
        lock.lock()
        guard let entry = entries.removeValue(forKey: key) else { lock.unlock(); return false }
        total -= entry.cost
        order.removeAll { $0 == key }
        lock.unlock()
        if callEvict { entry.onEvict() }
        return true
    }

    /// 全放出する(メモリ逼迫時)。全エントリの `onEvict` を LRU 順に呼ぶ。
    public func purgeAll() {
        lock.lock()
        let evicted: [(String, EvictHandler)] = order.compactMap { key in
            entries[key].map { (key, $0.onEvict) }
        }
        entries.removeAll()
        order.removeAll()
        total = 0
        lock.unlock()
        for (_, handler) in evicted { handler() }
    }

    // MARK: - 内部

    /// ロック保持中に呼ぶこと。上限を超えている間、LRU 順に取り出す。
    private func collectEvictionsLocked() -> [(String, EvictHandler)] {
        guard let limit = limitBytes else { return [] }
        var out: [(String, EvictHandler)] = []
        while total > limit, let victimKey = order.first, let victim = entries[victimKey] {
            order.removeFirst()
            entries.removeValue(forKey: victimKey)
            total -= victim.cost
            out.append((victimKey, victim.onEvict))
        }
        return out
    }
}

/// メモリプレッシャ通知(DispatchSource)から `CacheBudgetManager.purgeAll()` を呼ぶ小さな監視クラス。
/// 警告・緊急レベルの逼迫で全放出する。通常レベルでは何もしない。
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let manager: CacheBudgetManager
    private var source: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "moviecut.memory-pressure", qos: .utility)

    public init(manager: CacheBudgetManager) {
        self.manager = manager
    }

    public func start() {
        stop()
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            if event.contains(.warning) || event.contains(.critical) {
                self.manager.purgeAll()
            }
        }
        src.activate()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
