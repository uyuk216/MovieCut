import Foundation
import CoreGraphics

// プロキシのワークフロー(収集・自動作成の判定・外部プロキシの関連付け)。画面に依存しない純粋なロジック。
// 原則は変わらない: プロキシはプレビュー専用で、書き出しは常に原本を読む。

/// 素材がどこで使われているか。
public enum ProxySourceContext: Hashable, Sendable { case topLevel, compound, scene }

public struct ProxySourceInfo: Equatable {
    public var path: String
    public var contexts: Set<ProxySourceContext>
}

public enum ProxySources {
    /// 映像素材を、複合クリップの中・シーン定義の中まで集める。パス昇順、同じパスは contexts を合わせて 1 件にする。
    public static func collect(in p: Project) -> [ProxySourceInfo] {
        var found: [String: Set<ProxySourceContext>] = [:]
        var visitedScenes: Set<String> = []
        func walk(_ tracks: [Track], context: ProxySourceContext, extra: Set<ProxySourceContext>, stack: [String]) {
            for tr in tracks {
                for c in tr.clips {
                    if c.type == .video, let s = c.src, !s.isEmpty {
                        found[s, default: []].formUnion(extra.union([context]))
                    } else if c.type == .compound {
                        // 循環(同じ id の入れ子)と深すぎる入れ子は辿らない
                        guard stack.count < CompoundEditing.maxDepth, !stack.contains(c.id) else { continue }
                        walk(c.tracks ?? [], context: .compound, extra: extra, stack: stack + [c.id])
                    } else if c.type == .scene {
                        guard let sid = c.sceneId, !visitedScenes.contains(sid),
                              let sc = p.scenes.first(where: { $0.id == sid }) else { continue }
                        visitedScenes.insert(sid)
                        walk(sc.tracks, context: .scene, extra: extra.union([.scene]), stack: stack)
                    }
                }
            }
        }
        walk(p.tracks, context: .topLevel, extra: [], stack: [])
        return found.keys.sorted().map { ProxySourceInfo(path: $0, contexts: found[$0] ?? []) }
    }

    public static func videoPaths(in p: Project) -> [String] { collect(in: p).map(\.path) }
}

public enum ProxyAutoCreate {
    public enum SkipReason: Equatable { case disabled, notVideo, alreadyExists, smallEnough }
    public enum Decision: Equatable { case create, skip(SkipReason) }

    /// 取り込み時にプロキシを作るかどうか。表示の短辺が 540 以下なら縮める意味がないので作らない。大きさが不明(nil)なら作る側に倒す。
    public static func decide(enabled: Bool, isVideo: Bool, hasExistingProxy: Bool, displayedShortSide: CGFloat?) -> Decision {
        if !enabled { return .skip(.disabled) }
        if !isVideo { return .skip(.notVideo) }
        if hasExistingProxy { return .skip(.alreadyExists) }
        if let s = displayedShortSide, s <= ProxyStore.shortSide { return .skip(.smallEnough) }
        return .create
    }
}

public enum ProxyStatus: Equatable { case external(String), generated(String), none }

public enum ProxyLinks {
    /// 外部プロキシを関連付けたコピーを返す(再関連付けは上書き)。素材がこのプロジェクトの映像でない・空・自分自身なら nil。
    public static func attach(to p: Project, source: String, proxy: String) -> Project? {
        guard !proxy.isEmpty, proxy != source, ProxySources.videoPaths(in: p).contains(source) else { return nil }
        var q = p
        q.proxyLinks[source] = proxy
        return q
    }

    public static func detach(from p: Project, source: String) -> Project {
        var q = p
        q.proxyLinks[source] = nil
        return q
    }

    public static func linkedProxy(for source: String, in p: Project) -> String? { p.proxyLinks[source] }

    /// 外部リンク(ファイルが実在するとき)を優先し、無ければ生成済み(プロジェクト内の記録 → 従来のアプリ側)。
    /// リンク先が消えていれば生成済みに落ちる(プレビューを壊さない)。`directory` は従来のアプリ側(暫定置き場)、`projectDir` はプロジェクトファイルのフォルダ(未保存は nil)。
    public static func status(for source: String, in p: Project, directory: URL = ProxyStore.defaultDirectory(),
                              projectDir: URL? = nil,
                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> ProxyStatus {
        if let link = p.proxyLinks[source], fileExists(link) { return .external(link) }
        if let gen = ProxyAssets.locate(source: source, in: p, projectDir: projectDir, legacyDirectory: directory) { return .generated(gen.url.path) }
        return .none
    }

    public static func resolve(for source: String, in p: Project, directory: URL = ProxyStore.defaultDirectory(),
                               projectDir: URL? = nil,
                               fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        switch status(for: source, in: p, directory: directory, projectDir: projectDir, fileExists: fileExists) {
        case .external(let s), .generated(let s): return s
        case .none: return nil
        }
    }
}
