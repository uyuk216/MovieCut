import Foundation
import Security

/// 秘密(APIキー)の保存先の差し替え口。本番はキーチェーン、試験はメモリ。
public protocol SecretBackend: AnyObject, Sendable {
    func read(account: String) -> String?
    /// 空文字は削除として扱う。
    func write(_ value: String, account: String)
    func delete(account: String)
}

/// メモリだけの保存先(試験用。実際のキーチェーンには触らない)。
public final class InMemorySecretBackend: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    public init() {}
    public func read(account: String) -> String? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func write(_ value: String, account: String) { lock.lock(); defer { lock.unlock() }; items[account] = value }
    public func delete(account: String) { lock.lock(); defer { lock.unlock() }; items[account] = nil }
}

/// macOS のキーチェーン(汎用パスワード)。service は版ごとのバンドル ID、account はキー名。
public final class KeychainSecretBackend: SecretBackend, @unchecked Sendable {
    public let service: String
    public init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func write(_ value: String, account: String) {
        guard !value.isEmpty else { delete(account: account); return }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func delete(account: String) { SecItemDelete(query(account) as CFDictionary) }
}

/// APIキーの読み書き。キーはログや UserDefaults に出さない。
public struct SecretStore: Sendable {
    public let backend: SecretBackend
    public init(backend: SecretBackend) { self.backend = backend }

    /// 既定の保存先。試験(XCTest 内)ではメモリ、それ以外は版ごとのキーチェーン。
    public static let shared: SecretStore = {
        if NSClassFromString("XCTestCase") != nil { return SecretStore(backend: InMemorySecretBackend()) }
        return SecretStore(backend: KeychainSecretBackend(service: AppEdition.current.bundleIdentifier))
    }()

    public func get(_ account: String) -> String { backend.read(account: account) ?? "" }

    public func set(_ value: String, account: String) {
        if value.isEmpty { backend.delete(account: account) } else { backend.write(value, account: account) }
    }

    /// UserDefaults に平文で残っている値をキーチェーンへ移し、UserDefaults から消す。キーチェーン側に値があればそれを優先する。
    public func load(account: String, migratingFrom d: UserDefaults) -> String {
        if let legacy = d.string(forKey: account) {
            if !legacy.isEmpty, (backend.read(account: account) ?? "").isEmpty {
                backend.write(legacy, account: account)
                // 移行できた(読み戻せる)ときだけ平文の控えを消す。書き込みが失敗したら
                // 控えを残し、次回また移行を試す(控えまで消すとキーを失う)。
                if (backend.read(account: account) ?? "") == legacy { d.removeObject(forKey: account) }
            } else {
                d.removeObject(forKey: account)
            }
        }
        return get(account)
    }
}
