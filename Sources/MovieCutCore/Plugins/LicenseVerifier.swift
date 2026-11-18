import Foundation
import CryptoKit

/// ライセンス検証の結果。
public enum LicenseVerificationResult: String, Equatable, Sendable {
/// 承認。
case valid
/// コードが登録されていない/一致しない。
case invalidCode
/// コードはあるが、別のデバイスに紐付いている。
case deviceMismatch
/// そのプラグイン/コードの登録自体が無い。
case notFound
}

/// ライセンス検証の接続点。
///
/// 現状の実装は `InMemoryLicenseVerifier` のみで、照合はメモリ上の
/// ストアに対して行う(再起動で消える・サーバ照合なし)。これは基盤の形を先に固定するための
/// スタブであり、本番では「購入コードをサーバへ送って照合し、検証済みトークンを受け取る」
/// 実装に差し替える想定。その際もこのプロトコル(プラグイン id × コード × デバイス ID → 結果)
/// は変えずに済む形にしてある。平文のコードは保持せず、SHA-256 ハッシュだけを照合する。
public protocol LicenseVerifying: AnyObject {
func verify(pluginID: String, licenseCode: String, deviceID: String) -> LicenseVerificationResult
}

/// ライセンスコードの正規化とハッシュ化。コードは前後の空白とハイフンを取り除き、大文字にそろえてから照合する。
public enum LicenseCode {
public static func normalized(_ code: String) -> String {
code.uppercased().filter {!$0.isWhitespace && $0 != "-"}
}

/// SHA-256 ハッシュ(16 進文字列)。平文コードを保存・ログ出力しないための表現。
public static func sha256Hex(_ string: String) -> String {
SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0)}.joined()
}

/// 照合用ハッシュ。プラグイン id とデバイス ID を混ぜることで、同じコードでも
/// 「プラグイン違い」「デバイス違い」の流用がそのまま一致しないようにする。
public static func bindingHash(pluginID: String, licenseCode: String, deviceID: String) -> String {
sha256Hex("\(pluginID)|\(normalized(licenseCode))|\(deviceID)")
}

/// コード単体のハッシュ(デバイス紐付けの有無を判定する材料)。
public static func codeHash(pluginID: String, licenseCode: String) -> String {
sha256Hex("\(pluginID)|\(normalized(licenseCode))")
}
}

/// メモリ上のライセンスストア(スタブ用)。登録は「発行済みコード」を模して行う。
public final class InMemoryLicenseStore {
/// コードハッシュ → 紐付け済みデバイス ID。
private var deviceByCodeHash: [String: String] = [:]
private let lock = NSLock()

public init() {}

/// 発行済みライセンスとして登録する(平文は保持しない)。
public func issue(pluginID: String, licenseCode: String, deviceID: String) {
let key = LicenseCode.codeHash(pluginID: pluginID, licenseCode: licenseCode)
lock.withLock { deviceByCodeHash[key] = deviceID}
}

/// 登録を取り消す(返金・無効化の模擬)。
public func revoke(pluginID: String, licenseCode: String) {
let key = LicenseCode.codeHash(pluginID: pluginID, licenseCode: licenseCode)
_ = lock.withLock { deviceByCodeHash.removeValue(forKey: key) }
}

/// コードハッシュに紐付いたデバイス ID。未登録なら nil。
public func deviceID(forCodeHash codeHash: String) -> String? {
lock.withLock { deviceByCodeHash[codeHash]}
}

public var count: Int { lock.withLock { deviceByCodeHash.count}}
}

/// スタブ実装: メモリ上のストアと照合するライセンス検証器。
/// 本番のサーバ実装に差し替えるまでの仮実装であることに注意(永続化・署名検証・失効確認は無い)。
public final class InMemoryLicenseVerifier: LicenseVerifying {
public let store: InMemoryLicenseStore

public init(store: InMemoryLicenseStore = InMemoryLicenseStore()) {
self.store = store
}

public func verify(pluginID: String, licenseCode: String, deviceID: String) -> LicenseVerificationResult {
guard !LicenseCode.normalized(licenseCode).isEmpty else { return .invalidCode}
let codeHash = LicenseCode.codeHash(pluginID: pluginID, licenseCode: licenseCode)
guard let boundDevice = store.deviceID(forCodeHash: codeHash) else { return .notFound}
// 紐付けの照合はハッシュ同士で行う(平文デバイス ID の単純比較にしない)。
let expected = LicenseCode.bindingHash(pluginID: pluginID, licenseCode: licenseCode, deviceID: boundDevice)
let actual = LicenseCode.bindingHash(pluginID: pluginID, licenseCode: licenseCode, deviceID: deviceID)
return expected == actual ? .valid : .deviceMismatch
}
}
