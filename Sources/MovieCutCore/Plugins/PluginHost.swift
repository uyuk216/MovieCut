import Foundation

/// プラグインまわりの失敗。
public enum PluginError: Error, Equatable {
/// manifest.json の内容が不正。
case invalidManifest(url: URL, reason: String)
/// 登録されていないプラグイン id。
case notRegistered(pluginID: String)
/// 担当プラグインが見つからない engine 識別子。
case noVoicePlugin(engineID: String)
/// プラグインは見つかったが音声プロバイダを持っていない。
case voiceProviderMissing(pluginID: String)
/// 担当プラグインが見つからないエフェクト識別子。
case noEffectPlugin(effectID: String)
/// プラグインは見つかったがエフェクトプロバイダを持っていない。
case effectProviderMissing(pluginID: String)
/// 担当プラグインが見つからない音声エフェクト識別子。
case noAudioEffectPlugin(effectID: String)
/// プラグインは見つかったが音声エフェクトプロバイダを持っていない。
case audioEffectProviderMissing(pluginID: String)
/// 担当プラグインが見つからない書き出し形式識別子。
case noExportPlugin(formatID: String)
/// プラグインは見つかったが書き出しバックエンドを持っていない。
case exportBackendMissing(pluginID: String)
/// ライセンス検証で拒否された。
case licenseDenied(pluginID: String, result: LicenseVerificationResult)
/// アプリバージョンがプラグインの最小要件を満たさない。
case incompatibleAppVersion(pluginID: String, required: String, current: String)
}

/// 実体化されたプラグイン。本体が提供するサービスをここに集約する。
///
/// 接続点は音声(`VoiceProvider`)・映像エフェクト(`VideoEffectProviding`)・
/// 音声エフェクト(`AudioEffectProviding`)・書き出し(`ExportBackendProviding`)の 4 種。
/// importer フックは将来ここに口を追加する想定で、マニフェスト側の種別だけ先に定義してある。
public struct LoadedPlugin {
public var manifest: PluginManifest
public var directory: URL
/// 音声フックの実体。音声を提供しないプラグインでは nil。
public var voiceProvider: (any VoiceProvider)?
/// エフェクトフックの実体。エフェクトを提供しないプラグインでは nil。
public var effectProvider: (any VideoEffectProviding)?
/// 音声エフェクトフックの実体。音声エフェクトを提供しないプラグインでは nil。
public var audioEffectProvider: (any AudioEffectProviding)?
/// 書き出しフックの実体。書き出しを提供しないプラグインでは nil。
public var exportBackend: (any ExportBackendProviding)?

public init(manifest: PluginManifest, directory: URL, voiceProvider: (any VoiceProvider)? = nil,
            effectProvider: (any VideoEffectProviding)? = nil,
            exportBackend: (any ExportBackendProviding)? = nil,
            audioEffectProvider: (any AudioEffectProviding)? = nil) {
self.manifest = manifest
self.directory = directory
self.voiceProvider = voiceProvider
self.effectProvider = effectProvider
self.exportBackend = exportBackend
self.audioEffectProvider = audioEffectProvider
}
}

/// プラグイン本体の実体化を担うローダ。
///
/// 動的ライブラリ(.bundle /.dylib)の読み込みはまだ行わない。
/// 理由: 署名・公証・サンドボックスとの兼ね合いと、プラグイン配布形式(ユーザーのサーバから
/// 暗号化パッケージを落とす方式)が未確定なため。まず「マニフェスト登録 → 初回使用時にだけ
/// ローダ経由で実体化」という基盤の形を固定し、実体化手段はこのプロトコルの裏側に閉じ込める。
/// 将来はバンドル読み込みローダを差し込むだけで移行できる。
public protocol PluginLoader: AnyObject {
/// プラグイン本体を実体化する。`PluginHost` からは初回使用時に 1 回だけ呼ばれる。
func loadPlugin(manifest: PluginManifest, directory: URL) throws -> LoadedPlugin
}

/// クロージャで実体化方法を与えるローダ。テストと、アプリ組み込みプラグインの登録に使う。
public final class ClosurePluginLoader: PluginLoader {
private let body: (PluginManifest, URL) throws -> LoadedPlugin
public init(_ body: @escaping (PluginManifest, URL) throws -> LoadedPlugin) { self.body = body}
public func loadPlugin(manifest: PluginManifest, directory: URL) throws -> LoadedPlugin {
try body(manifest, directory)
}
}

/// 登録済みプラグインの管理と遅延読み込み。
///
/// - 登録(`register`)時点ではマニフェストしか持たない。本体は読み込まない。
/// - 本体の実体化は `loadIfNeeded` / `voiceProvider(forEngine:)` の初回呼び出し時だけ。
/// - 実体化したかどうかは `isLoaded(pluginID:)` / `loadedPluginIDs` で外から観測できる(テスト用に公開)。
/// - `requiresLicense` なプラグインは、実体化の前にライセンス検証を通す。検証に使う
/// コードは `setLicenseCode(_:forPluginID:)` で渡す(保存は呼び出し側の責務。ここでは保持のみ)。
public final class PluginHost {
/// 互換性判定に使うアプリバージョン。
public let appVersion: String
/// ライセンス照合先のデバイス ID。
public let deviceID: String

private let loader: any PluginLoader
private let licenseVerifier: (any LicenseVerifying)?

private var discoveredByID: [String: DiscoveredPlugin] = [:]
private var registrationOrder: [String] = []
private var loadedByID: [String: LoadedPlugin] = [:]
private var licenseCodes: [String: String] = [:]
private let lock = NSLock()
/// 初回ロードの直列化用(キャッシュ確認とロードの間に割り込まれて、ローダが二重に走らないように)。
private let loadLock = NSLock()

public init(loader: any PluginLoader,
licenseVerifier: (any LicenseVerifying)? = nil,
deviceID: String = "",
appVersion: String = "1.0.0") {
self.loader = loader
self.licenseVerifier = licenseVerifier
self.deviceID = deviceID
self.appVersion = appVersion
}

// MARK: - 登録(マニフェストのみ。本体は読まない)

/// 探索結果をまとめて登録する。同 id の再登録は先勝ち。
public func register(_ result: PluginDiscoveryResult) {
for plugin in result.plugins { register(plugin)}
}

public func register(_ plugin: DiscoveredPlugin) {
lock.withLock {
guard discoveredByID[plugin.manifest.id] == nil else { return}
discoveredByID[plugin.manifest.id] = plugin
registrationOrder.append(plugin.manifest.id)
}
}

public func register(manifest: PluginManifest, directory: URL) {
register(DiscoveredPlugin(manifest: manifest,
directory: directory,
manifestURL: directory.appendingPathComponent(PluginDiscovery.manifestFileName)))
}

/// 登録済みマニフェストの一覧(登録順)。
public var registeredManifests: [PluginManifest] {
lock.withLock { registrationOrder.compactMap { discoveredByID[$0]?.manifest}}
}

public func manifest(forPluginID pluginID: String) -> PluginManifest? {
lock.withLock { discoveredByID[pluginID]?.manifest}
}

// MARK: - 遅延読み込みの観測

/// そのプラグインの本体が既に実体化されているか。
public func isLoaded(pluginID: String) -> Bool {
lock.withLock { loadedByID[pluginID] != nil}
}

/// 実体化済みプラグイン id の集合。
public var loadedPluginIDs: Set<String> {
lock.withLock { Set(loadedByID.keys)}
}

// MARK: - ライセンス

/// プラグインに使うライセンスコードを設定する(検証は実体化の直前に行う)。
public func setLicenseCode(_ code: String?, forPluginID pluginID: String) {
lock.withLock {
if let code { licenseCodes[pluginID] = code} else { licenseCodes.removeValue(forKey: pluginID)}
}
}

/// ライセンス検証だけを先に行う(設定画面などで使う想定)。検証器が無い/不要なプラグインは `.valid`。
public func verifyLicense(forPluginID pluginID: String) -> LicenseVerificationResult {
let snapshot: (PluginManifest?, String?) = lock.withLock {
(discoveredByID[pluginID]?.manifest, licenseCodes[pluginID])
}
guard let manifest = snapshot.0 else { return .notFound}
guard manifest.requiresLicense, let licenseVerifier else { return .valid }
guard let code = snapshot.1, !code.isEmpty else { return .notFound}
return licenseVerifier.verify(pluginID: pluginID, licenseCode: code, deviceID: deviceID)
}

// MARK: - 実体化

/// プラグイン本体を取得する。未実体化ならここで初めてローダを呼ぶ(結果は保持し、2 回目以降は再利用)。
public func loadIfNeeded(pluginID: String) throws -> LoadedPlugin {
let already: LoadedPlugin? = lock.withLock { loadedByID[pluginID]}
if let already { return already}
// 初回ロードは 1 回だけに直列化する(並行した初回アクセスでローダの初期化が二重に走らないよう、
// loadLock の中でキャッシュを確かめ直してからロードする)。
return try loadLock.withLock {
let cached: LoadedPlugin? = lock.withLock { loadedByID[pluginID]}
if let cached { return cached}

let discovered: DiscoveredPlugin? = lock.withLock { discoveredByID[pluginID]}
guard let discovered else { throw PluginError.notRegistered(pluginID: pluginID)}
let manifest = discovered.manifest

guard manifest.isCompatible(withAppVersion: appVersion) else {
throw PluginError.incompatibleAppVersion(pluginID: pluginID,
required: manifest.minimumAppVersion ?? "",
current: appVersion)
}

if manifest.requiresLicense, let licenseVerifier {
let code: String? = lock.withLock { licenseCodes[pluginID]}
guard let code, !code.isEmpty else {
throw PluginError.licenseDenied(pluginID: pluginID, result: .notFound)
}
let result = licenseVerifier.verify(pluginID: pluginID, licenseCode: code, deviceID: deviceID)
guard result == .valid else {
throw PluginError.licenseDenied(pluginID: pluginID, result: result)
}
}

let loaded = try loader.loadPlugin(manifest: manifest, directory: discovered.directory)
lock.withLock { loadedByID[pluginID] = loaded }
return loaded
}
}

// MARK: - 音声フック

/// キャラの `engine` 識別子を担当するプラグインの `VoiceProvider` を解決する。
/// 該当プラグインはこの呼び出しで初めて実体化される(遅延読み込み)。
/// 担当プラグインが登録されていなければ nil(呼び出し側がコア既定の扱いに落とせるよう、ここでは投げない版)。
public func voiceProviderIfAvailable(forEngine engineID: String) throws -> (any VoiceProvider)? {
guard let manifest = registeredManifests.first(where: { $0.handlesVoiceEngine(engineID)}) else { return nil}
let loaded = try loadIfNeeded(pluginID: manifest.id)
return loaded.voiceProvider
}

/// `voiceProviderIfAvailable` の「無ければエラー」版。
public func voiceProvider(forEngine engineID: String) throws -> any VoiceProvider {
guard let manifest = registeredManifests.first(where: { $0.handlesVoiceEngine(engineID)}) else {
throw PluginError.noVoicePlugin(engineID: engineID)
}
let loaded = try loadIfNeeded(pluginID: manifest.id)
guard let provider = loaded.voiceProvider else {
throw PluginError.voiceProviderMissing(pluginID: manifest.id)
}
return provider
}

/// キャラから直接解決する(接続点: `Character.engine` が解決キー)。
public func voiceProvider(for character: Character) throws -> any VoiceProvider {
try voiceProvider(forEngine: character.engine)
}

// MARK: - エフェクトフック

/// エフェクト識別子(`Effect.kind`)を担当するプラグインの `VideoEffectProviding` を解決する。
/// 該当プラグインはこの呼び出しで初めて実体化される(遅延読み込み)。
/// 担当プラグインが登録されていなければ nil(呼び出し側がコア既定の扱いに落とせるよう、ここでは投げない版)。
public func effectProviderIfAvailable(forEffectID effectID: String) throws -> (any VideoEffectProviding)? {
guard let manifest = registeredManifests.first(where: { $0.handlesEffect(effectID)}) else { return nil}
let loaded = try loadIfNeeded(pluginID: manifest.id)
return loaded.effectProvider
}

/// `effectProviderIfAvailable` の「無ければエラー」版。
public func effectProvider(forEffectID effectID: String) throws -> any VideoEffectProviding {
guard let manifest = registeredManifests.first(where: { $0.handlesEffect(effectID)}) else {
throw PluginError.noEffectPlugin(effectID: effectID)
}
let loaded = try loadIfNeeded(pluginID: manifest.id)
guard let provider = loaded.effectProvider else {
throw PluginError.effectProviderMissing(pluginID: manifest.id)
}
return provider
}

/// 登録済みエフェクトプラグインすべてのプロバイダ(登録順・重複なし)。
/// エフェクトフックを持つプラグインはこの呼び出しで実体化される(記述子が本体側にあるため)。
/// 実体化に失敗したプラグインは飛ばす(1 個の故障で全体が止まらないように)。
public func allEffectProviders() -> [any VideoEffectProviding] {
var out: [any VideoEffectProviding] = []
for manifest in registeredManifests where manifest.provides(.effect) {
guard let loaded = try? loadIfNeeded(pluginID: manifest.id), let provider = loaded.effectProvider else { continue }
out.append(provider)
}
return out
}

/// 登録済みエフェクトプラグインが提供するエフェクト記述子の一覧(登録順)。
public func effectDescriptors() -> [PluginEffectDescriptor] {
allEffectProviders().flatMap { $0.effectDescriptors }
}

// MARK: - 音声エフェクトフック

/// 音声エフェクト識別子を担当するプラグインの `AudioEffectProviding` を解決する。
/// 該当プラグインはこの呼び出しで初めて実体化される(遅延読み込み)。
/// 担当プラグインが登録されていなければ nil(呼び出し側がバイパスに落とせるよう、ここでは投げない版)。
public func audioEffectProviderIfAvailable(forAudioEffectID effectID: String) throws -> (any AudioEffectProviding)? {
guard let manifest = registeredManifests.first(where: { $0.handlesAudioEffect(effectID)}) else { return nil}
let loaded = try loadIfNeeded(pluginID: manifest.id)
return loaded.audioEffectProvider
}

/// `audioEffectProviderIfAvailable` の「無ければエラー」版。
public func audioEffectProvider(forAudioEffectID effectID: String) throws -> any AudioEffectProviding {
guard let manifest = registeredManifests.first(where: { $0.handlesAudioEffect(effectID)}) else {
throw PluginError.noAudioEffectPlugin(effectID: effectID)
}
let loaded = try loadIfNeeded(pluginID: manifest.id)
guard let provider = loaded.audioEffectProvider else {
throw PluginError.audioEffectProviderMissing(pluginID: manifest.id)
}
return provider
}

/// 登録済み音声エフェクトプラグインすべてのプロバイダ(登録順)。実体化に失敗したものは飛ばす。
public func allAudioEffectProviders() -> [any AudioEffectProviding] {
var out: [any AudioEffectProviding] = []
for manifest in registeredManifests where manifest.provides(.audioEffect) {
guard let loaded = try? loadIfNeeded(pluginID: manifest.id), let provider = loaded.audioEffectProvider else { continue }
out.append(provider)
}
return out
}

/// 登録済み音声エフェクトプラグインが提供する記述子の一覧(登録順)。
public func audioEffectDescriptors() -> [PluginAudioEffectDescriptor] {
allAudioEffectProviders().flatMap { $0.audioEffectDescriptors }
}

// MARK: - 書き出しフック

/// 書き出し形式識別子を担当するプラグインの `ExportBackendProviding` を解決する。
/// 該当プラグインはこの呼び出しで初めて実体化される(遅延読み込み)。
/// 担当プラグインが登録されていなければ nil(呼び出し側が内蔵書き出しに落とせるよう、ここでは投げない版)。
public func exportBackendIfAvailable(forFormat formatID: String) throws -> (any ExportBackendProviding)? {
guard let manifest = registeredManifests.first(where: { $0.handlesExportFormat(formatID)}) else { return nil}
let loaded = try loadIfNeeded(pluginID: manifest.id)
return loaded.exportBackend
}

/// `exportBackendIfAvailable` の「無ければエラー」版。
public func exportBackend(forFormat formatID: String) throws -> any ExportBackendProviding {
guard let manifest = registeredManifests.first(where: { $0.handlesExportFormat(formatID)}) else {
throw PluginError.noExportPlugin(formatID: formatID)
}
let loaded = try loadIfNeeded(pluginID: manifest.id)
guard let backend = loaded.exportBackend else {
throw PluginError.exportBackendMissing(pluginID: manifest.id)
}
return backend
}

/// 登録済み書き出しプラグインすべてのバックエンド(登録順・重複なし)。実体化に失敗したものは飛ばす。
public func allExportBackends() -> [any ExportBackendProviding] {
var out: [any ExportBackendProviding] = []
for manifest in registeredManifests where manifest.provides(.exporter) {
guard let loaded = try? loadIfNeeded(pluginID: manifest.id), let backend = loaded.exportBackend else { continue }
out.append(backend)
}
return out
}

/// 登録済み書き出しプラグインが提供する形式記述子の一覧(登録順)。
public func exportFormatDescriptors() -> [ExportFormatDescriptor] {
allExportBackends().flatMap { $0.formatDescriptors }
}
}
