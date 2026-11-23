import Foundation

/// パッケージとして保存: プロジェクトと、使っている素材を 1 つのフォルダにまとめる。
/// 素材は `media/` に置き、プロジェクトの参照は相対パスにする(目印 `mediaHints` も同じ相対パス)。
public enum MediaPackage {
    /// コピーの計画。`copies` の `from` は元のパス、`to` はパッケージ内の相対パス(例 "media/a.mp4")。
    public struct Plan: Equatable {
        public var project: Project
        public var copies: [Copy]
        /// 元のファイルが無くてコピーできなかった参照(元のパス)。
        public var skipped: [String]
        public struct Copy: Equatable {
            public var from: String
            public var to: String
        }
    }

    /// 素材の参照を集めて計画を立てる。同じ元のパスは 1 回だけコピーし、同名の別ファイルには番号を付ける。
    /// `size` は各素材のバイト数(読めなければ nil)。`exists` でコピー元の有無を判定する。
    public static func plan(_ project: Project, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                            size: (String) -> Int64? = { _ in nil }) -> Plan {
        var p = project
        var copies: [Plan.Copy] = []
        var skipped: [String] = []
        var mapping: [String: String] = [:]     // 元のパス → パッケージ内の相対パス
        var usedNames: Set<String> = []
        var hints: [String: MediaHint] = [:]

        func destination(for src: String) -> String {
            if let d = mapping[src] { return d }
            let base = (src as NSString).lastPathComponent
            var name = base
            var n = 2
            let stem = (base as NSString).deletingPathExtension
            let ext = (base as NSString).pathExtension
            while usedNames.contains(name.lowercased()) {
                name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                n += 1
            }
            usedNames.insert(name.lowercased())
            let rel = "media/\(name)"
            mapping[src] = rel
            return rel
        }

        // 最上位だけでなく、複合の内側・シーン定義の中の素材も集める(漏れると、開いた先で素材が欠ける)
        func walk(_ tracks: inout [Track]) {
            for ti in tracks.indices {
                for ci in tracks[ti].clips.indices {
                    if let src = tracks[ti].clips[ci].src, !src.isEmpty {
                        if !exists(src) {
                            if !skipped.contains(src) { skipped.append(src) }
                        } else {
                            let rel = destination(for: src)
                            if mapping[src] == rel, !copies.contains(where: { $0.from == src }) {
                                copies.append(Plan.Copy(from: src, to: rel))
                                hints[src] = MediaHint(relative: rel, size: size(src))
                            }
                            tracks[ti].clips[ci].src = rel
                        }
                    }
                    if tracks[ti].clips[ci].tracks != nil {
                        var inner = tracks[ti].clips[ci].tracks!
                        walk(&inner)
                        tracks[ti].clips[ci].tracks = inner
                    }
                }
            }
        }
        walk(&p.tracks)
        for si in p.scenes.indices { walk(&p.scenes[si].tracks) }
        p.mediaHints = hints
        // フィンガープリントと素材プールも、パッケージ後のパスへ付け替える
        var fps: [String: MediaFingerprint] = [:]
        for (k, v) in p.mediaFingerprints { fps[mapping[k] ?? k] = v }
        p.mediaFingerprints = fps
        p.mediaPool = p.mediaPool.map { mapping[$0] ?? $0 }
        return Plan(project: p, copies: copies, skipped: skipped)
    }

    /// 計画どおりに `folder` へ書く。`folder` は作成する。プロジェクトは `folder/<name>.mcpjc` に書く。
    /// 戻り値は書いたプロジェクトのファイル。素材のコピーに失敗したら例外(途中の成果物は残す)。
    @discardableResult
    public static func write(_ plan: Plan, to folder: URL, projectName: String, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for c in plan.copies {
            let dest = folder.appendingPathComponent(c.to)
            try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dest.path) { try fileManager.removeItem(at: dest) }
            try fileManager.copyItem(atPath: c.from, toPath: dest.path)
        }
        let file = folder.appendingPathComponent("\(projectName).\(ProjectFileExtension.current)")
        try plan.project.save(to: file)
        return file
    }
}
