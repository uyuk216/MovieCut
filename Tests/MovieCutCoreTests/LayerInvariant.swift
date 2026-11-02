import XCTest
import MovieCutCore

/// 全体の不変条件: 同じレイヤーのクリップは時間で重ならない(接するのは可)。複合の中のレイヤーも見る。
/// 重なりの説明の文字列を返す(空なら問題なし)。
func layerOverlaps(_ project: Project) -> [String] {
    var out: [String] = []
    func check(_ tracks: [Track], _ label: String) {
        for (ti, tr) in tracks.enumerated() {
            let cs = tr.clips.sorted { $0.start < $1.start }
            for i in 0..<cs.count {
                for j in (i + 1)..<cs.count where cs[j].start < cs[i].start + cs[i].duration - 1e-9 {
                    out.append("\(label)レイヤー\(ti) \(cs[i].id)[\(cs[i].start),\(cs[i].start + cs[i].duration)) と \(cs[j].id)[\(cs[j].start),…)")
                }
                if cs[i].type == .compound { check(cs[i].tracks ?? [], "複合\(cs[i].id)の中の") }
            }
        }
    }
    check(project.tracks, "")
    return out
}

func assertNoLayerOverlaps(_ project: Project, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    let o = layerOverlaps(project)
    XCTAssertTrue(o.isEmpty, "同じレイヤーでクリップが重なっている \(message): \(o.prefix(5))", file: file, line: line)
}
