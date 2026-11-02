import Foundation

/// 背景抜きで書き出した PNG の管理(純粋な計算)。
public enum CutoutCache {
    /// `paths` のうち、どのクリップの素材(src)にも使われていないもの(順番は保つ)。
    /// 背景を抜く処理は、PNG を書いてからクリップを差し替える。クリップが消えていたときは、この残骸を消す。
    public static func unreferenced(_ paths: [String], in p: Project) -> [String] {
        let used = Set(p.allClips.compactMap(\.src))
        return paths.filter { !used.contains($0) }
    }
}
