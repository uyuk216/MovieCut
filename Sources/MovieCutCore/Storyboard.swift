import Foundation
import CoreGraphics

// MARK: - 絵コンテ(出力 ▸ 絵コンテを書き出す…)
//
// 全体の長さを枚数で等分し、各区間の中央のコマを格子に並べた 1 枚の PNG にする。
// コマは `Renderer`(プレビューと同じ経路)で描く。セルは縦横比を保って中に収め、余白は背景色。時刻の文字は入れない。

public enum Storyboard {
    public static let defaultCount = 12
    public static let maxCount = 64
    public static let defaultColumns = 4
    /// 1 セルの横幅(px)。高さは縦横比から決める。
    public static let cellWidth = 480

    public enum Failure: Error, Equatable {
        /// 長さが無い(0 秒以下・非有限)
        case noLength
        case render
    }

    /// 全体(0〜duration)を count 個に区切った、各区間の中央の時刻。count は 1〜64 に直す。長さが 0 以下なら空。
    public static func times(duration: Double, count: Int = defaultCount) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let n = min(max(1, count), maxCount)
        let step = duration / Double(n)
        return (0..<n).map { (Double($0) + 0.5) * step }
    }

    /// 枚数と列数から、列と行の数。列は 1 以上・枚数を超えない。
    public static func grid(count: Int, columns: Int = defaultColumns) -> (columns: Int, rows: Int) {
        let total = max(1, count)
        let c = min(max(1, columns), total)
        return (c, (total + c - 1) / c)
    }

    /// 1 セルの大きさ(横 `cellWidth`、高さは縦横比から。各 2 以上の偶数)。
    public static func cellSize(width: Int, height: Int) -> CGSize {
        guard width > 0, height > 0 else { return CGSize(width: CGFloat(cellWidth), height: CGFloat(cellWidth * 9 / 16)) }
        let h = (Double(cellWidth) * Double(height) / Double(width) / 2).rounded() * 2
        return CGSize(width: CGFloat(cellWidth), height: CGFloat(max(2, h)))
    }

    /// コマを格子に並べて 1 枚にする。上の行から左へ順に並べる。`frames` が空なら nil。
    public static func compose(_ frames: [CGImage], cell: CGSize, columns: Int, background: CGColor?) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        let g = grid(count: frames.count, columns: columns)
        let w = Int(cell.width) * g.columns, h = Int(cell.height) * g.rows
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(background ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        for (i, f) in frames.enumerated() {
            let col = i % g.columns, row = i / g.columns
            // CGContext は左下が原点。上の行から並べるので、行を反転して置く。
            let origin = CGPoint(x: CGFloat(col) * cell.width, y: CGFloat(g.rows - 1 - row) * cell.height)
            let fit = ThumbnailExporter.fittedRect(source: CGSize(width: f.width, height: f.height), canvas: cell)
            ctx.draw(f, in: fit.offsetBy(dx: origin.x, dy: origin.y))
        }
        return ctx.makeImage()
    }

    /// 絵コンテを `url` に書く(PNG)。長さは `project.endTime`。
    public static func write(project: Project, assets: RenderAssets = RenderAssets(), count: Int = defaultCount,
                             columns: Int = defaultColumns, to url: URL) throws {
        guard project.width > 0, project.height > 0 else { throw ExportError.noOutputSize(width: project.width, height: project.height) }
        let ts = times(duration: project.endTime, count: count)
        guard !ts.isEmpty else { throw Failure.noLength }
        let renderer = Renderer(project: project, assets: assets)
        var frames: [CGImage] = []
        frames.reserveCapacity(ts.count)
        for t in ts {
            guard let f = renderer.renderImage(t: t) else { throw Failure.render }
            frames.append(f)
        }
        let cell = cellSize(width: project.width, height: project.height)
        guard let board = compose(frames, cell: cell, columns: columns, background: parseHexColor(project.bg)) else { throw Failure.render }
        try StillExporter.writeImage(board, format: .png, to: url)
    }
}
