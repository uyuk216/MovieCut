import Foundation

/// 背景抜きで書き出した PNG の管理(純粋な計算)。
public enum CutoutCache {
    /// `paths` のうち、どのクリップの素材(src)にも使われていないもの(順番は保つ)。
    /// 背景を抜く処理は、PNG を書いてからクリップを差し替える。クリップが消えていたときは、この残骸を消す。
    public static func unreferenced(_ paths: [String], in p: Project) -> [String] {
        // シーン定義の中・複合の内側でだけ使われている素材も「使われている」
        var used = Set<String>()
        func walk(_ tracks: [Track]) {
            for tr in tracks {
                for c in tr.clips {
                    if let s = c.src { used.insert(s) }
                    if let inner = c.tracks { walk(inner) }
                }
            }
        }
        walk(p.tracks)
        for s in p.scenes { walk(s.tracks) }
        return paths.filter { !used.contains($0) }
    }
}
