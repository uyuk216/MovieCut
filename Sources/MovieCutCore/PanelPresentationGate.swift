import Foundation

/// ファイルパネル(開く/保存)の同時提示を防ぐ門番。純粋ロジックのみで AppKit に依存しない。
/// 提示中は 1 つだけ token を発行し、解放されるまで他の取得を断る。
public final class PanelPresentationGate: @unchecked Sendable {
    /// 提示の保持者を表す token。生成は gate 内部のみ。
    public struct Token: Equatable, Sendable {
        fileprivate let value: UInt64
        fileprivate init(value: UInt64) { self.value = value }
    }

    private let lock = NSLock()
    private var current: Token?
    private var counter: UInt64 = 0

    public init() {}

    /// 提示中か。
    public var isPresenting: Bool {
        lock.lock(); defer { lock.unlock() }
        return current != nil
    }

    /// 提示中でなければ token を返して提示中にする。提示中なら nil。
    public func tryAcquire() -> Token? {
        lock.lock(); defer { lock.unlock() }
        guard current == nil else { return nil }
        counter += 1
        let t = Token(value: counter)
        current = t
        return t
    }

    /// token が現在の保持者と一致するときだけ解除する。不一致・二重 release は何もしない。
    public func release(_ token: Token) {
        lock.lock(); defer { lock.unlock() }
        if current == token { current = nil }
    }

    /// パネルを出してよいか。全条件を満たすときだけ true。
    public static func shouldPresent(userInitiated: Bool, hasHostWindow: Bool,
                                     alreadyPresenting: Bool, environmentSuppressed: Bool) -> Bool {
        userInitiated && hasHostWindow && !alreadyPresenting && !environmentSuppressed
    }
}
