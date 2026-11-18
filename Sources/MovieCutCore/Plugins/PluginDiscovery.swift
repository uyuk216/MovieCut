import Foundation

/// 探索で見つかったプラグイン。マニフェストと置き場所だけを持ち、本体はまだ読み込んでいない。
public struct DiscoveredPlugin: Equatable, Sendable {
    public var manifest: PluginManifest
    /// プラグインフォルダ。
    public var directory: URL
    /// 読んだ `manifest.json` の場所。
    public var manifestURL: URL

    public init(manifest: PluginManifest, directory: URL, manifestURL: URL) {
        self.manifest = manifest
        self.directory = directory
        self.manifestURL = manifestURL
    }
}

/// 探索で読み飛ばしたフォルダ/ファイルと、その理由。
public struct PluginDiscoveryFailure: Equatable, Sendable {
    public var url: URL
    public var reason: String
    public init(url: URL, reason: String) { self.url = url; self.reason = reason }
}

/// 探索結果。成功分と失敗分を分けて返す(1 個壊れていても他は登録できるように)。
public struct PluginDiscoveryResult: Sendable {
    public var plugins: [DiscoveredPlugin]
    public var failures: [PluginDiscoveryFailure]
    public init(plugins: [DiscoveredPlugin], failures: [PluginDiscoveryFailure]) {
        self.plugins = plugins
        self.failures = failures
    }
}

/// プラグインフォルダ群の探索。
///
/// 指定ディレクトリの直下にある各サブフォルダを 1 プラグインとみなし、
/// その中の `manifest.json` **だけ** を読んで登録する。本体ファイルには一切触らない
/// (起動を軽く保つため。実体化は `PluginHost` の遅延読み込みに任せる)。
public enum PluginDiscovery {
    public static let manifestFileName = "manifest.json"

    /// `directories` の各直下を走査する。存在しないディレクトリは失敗として記録するだけで続行する。
    /// 同じプラグイン id が複数見つかった場合は先勝ち(走査順)にし、後発は失敗として記録する。
    public static func discover(in directories: [URL],
                                fileManager: FileManager = .default) -> PluginDiscoveryResult {
        var plugins: [DiscoveredPlugin] = []
        var failures: [PluginDiscoveryFailure] = []
        var seenIDs: Set<String> = []

        for root in directories {
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            } catch {
                failures.append(PluginDiscoveryFailure(url: root, reason: "ディレクトリを読めない: \(error.localizedDescription)"))
                continue
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let manifestURL = child.appendingPathComponent(manifestFileName)
                guard fileManager.fileExists(atPath: manifestURL.path) else {
                    failures.append(PluginDiscoveryFailure(url: child, reason: "manifest.json が無い"))
                    continue
                }
                do {
                    let manifest = try loadManifest(at: manifestURL)
                    guard seenIDs.insert(manifest.id).inserted else {
                        failures.append(PluginDiscoveryFailure(url: child, reason: "プラグイン id が重複: \(manifest.id)"))
                        continue
                    }
                    plugins.append(DiscoveredPlugin(manifest: manifest, directory: child, manifestURL: manifestURL))
                } catch {
                    failures.append(PluginDiscoveryFailure(url: manifestURL, reason: "manifest.json を読めない: \(error.localizedDescription)"))
                }
            }
        }
        return PluginDiscoveryResult(plugins: plugins, failures: failures)
    }

    /// `manifest.json` 1 個を読む。id / entryPoint が空のものは不正として弾く。
    public static func loadManifest(at url: URL) throws -> PluginManifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        guard !manifest.id.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.invalidManifest(url: url, reason: "id が空")
        }
        guard !manifest.entryPoint.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PluginError.invalidManifest(url: url, reason: "entryPoint が空")
        }
        return manifest
    }
}
