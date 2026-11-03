import Foundation
import CoreGraphics

// MARK: - サムネイル候補の自動選択(出力 ▸ サムネイル候補を書き出す…)
//
// 動画クリップ(選んでいなければ全体)の範囲を等間隔に調べ、各コマを点数にして、上位 N 個の時刻を返す。
// 点数 = 鮮明さ(ラプラシアンの分散)+ 明るさ(中間が最良)+ 顔(Vision。大きく写るほど高い)。
// 決定的: 同じ入力は同じ結果(同点は早い時刻を取る)。近すぎる時刻は重複として飛ばす。

public struct ThumbnailCandidate: Equatable, Sendable {
    /// プロジェクトの時刻(秒)。
    public var time: Double
    /// 総合の点数(0〜1)。
    public var score: Double
    public var sharpness: Double
    public var brightness: Double
    public var faceCount: Int

    public init(time: Double, score: Double, sharpness: Double, brightness: Double, faceCount: Int) {
        self.time = time; self.score = score; self.sharpness = sharpness; self.brightness = brightness; self.faceCount = faceCount
    }
}

public enum ThumbnailScoring {
    /// 点数の重み(合計 1)。
    public static let sharpnessWeight = 0.4
    public static let brightnessWeight = 0.25
    public static let faceWeight = 0.35
    /// 候補の数の既定と上限、調べるコマの数の既定。
    public static let defaultCount = 5
    public static let maxCount = 20
    public static let defaultSamples = 30
    /// 点数を測るときの画像の長辺(画素)。
    static let analysisSide = 160

    /// 8 ビットの輝度(0〜255、行優先)から鮮明さ(0〜1)。ラプラシアンの分散 v を v / (v + 300) で 0〜1 にする。
    public static func sharpness(luma: [UInt8], width w: Int, height h: Int) -> Double {
        guard w >= 3, h >= 3, luma.count >= w * h else { return 0 }
        var sum = 0.0, sumSq = 0.0
        var n = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = 4 * Double(luma[i]) - Double(luma[i - 1]) - Double(luma[i + 1]) - Double(luma[i - w]) - Double(luma[i + w])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        let mean = sum / n
        let variance = max(0, sumSq / n - mean * mean)
        return variance / (variance + 300)
    }

    /// 輝度の平均(0〜1)。
    public static func meanBrightness(luma: [UInt8]) -> Double {
        guard !luma.isEmpty else { return 0 }
        var s = 0
        for v in luma { s += Int(v) }
        return Double(s) / Double(luma.count) / 255
    }

    /// 明るさの点数(0〜1)。平均が 0.5 のとき 1、真っ黒・真っ白で 0 の三角形。
    public static func brightnessScore(mean: Double) -> Double {
        max(0, 1 - abs(mean - 0.5) / 0.5)
    }

    /// 顔の点数(0〜1)。顔が無ければ 0、あれば 0.5 + 最大の顔の面積(画面に対する割合)が 6% 以上で満点。
    public static func faceScore(faces: [CGRect]) -> Double {
        guard let largest = faces.map({ Double($0.width * $0.height) }).max() else { return 0 }
        return 0.5 + 0.5 * min(1, max(0, largest) / 0.06)
    }

    public static func combined(sharpness: Double, brightness: Double, faceScore: Double) -> Double {
        sharpnessWeight * sharpness + brightnessWeight * brightnessScore(mean: brightness) + faceWeight * faceScore
    }

    /// 画像を点数にする(時刻は呼び出し側が入れる)。
    public static func candidate(time: Double, image: CGImage, faces: [CGRect]) -> ThumbnailCandidate? {
        guard let (luma, w, h) = grayscale(image, maxSide: analysisSide) else { return nil }
        let sharp = sharpness(luma: luma, width: w, height: h)
        let bright = meanBrightness(luma: luma)
        let score = combined(sharpness: sharp, brightness: bright, faceScore: faceScore(faces: faces))
        return ThumbnailCandidate(time: time, score: score, sharpness: sharp, brightness: bright, faceCount: faces.count)
    }

    /// 長辺 `maxSide` に縮めた 8 ビットの輝度。
    static func grayscale(_ image: CGImage, maxSide: Int) -> ([UInt8], Int, Int)? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let k = min(1, Double(maxSide) / Double(longest))
        let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
        var data = [UInt8](repeating: 0, count: w * h)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (data, w, h) : nil
    }

    /// 調べる時刻: 範囲を `samples` 等分した各区間の中央。範囲が空なら空。
    public static func sampleTimes(start: Double, duration: Double, samples: Int) -> [Double] {
        guard duration > 0, samples > 0, start.isFinite, duration.isFinite else { return [] }
        let step = duration / Double(samples)
        return (0..<samples).map { start + step * (Double($0) + 0.5) }
    }

    /// 点数の高い順に `count` 個(同点は早い時刻)。`minGap` 秒より近い時刻は、点数の低い方を捨てる。結果は点数の高い順。
    public static func selectTop(_ all: [ThumbnailCandidate], count: Int, minGap: Double) -> [ThumbnailCandidate] {
        guard count > 0 else { return [] }
        let sorted = all.sorted { $0.score != $1.score ? $0.score > $1.score : $0.time < $1.time }
        var out: [ThumbnailCandidate] = []
        for c in sorted {
            if out.contains(where: { abs($0.time - c.time) < minGap }) { continue }
            out.append(c)
            if out.count >= count { break }
        }
        return out
    }
}

public enum ThumbnailCandidateFinder {
    /// `start`〜`start + duration` を調べて上位 `count` 個を返す。コマは `Renderer` と同じ描画(書き出しと同じ見た目)。
    /// 顔の検出器は差し替えられる(テストでは偽物)。
    public static func find(project: Project, assets: RenderAssets = RenderAssets(), start: Double, duration: Double,
                            count: Int = ThumbnailScoring.defaultCount, samples: Int = ThumbnailScoring.defaultSamples,
                            detector: FaceDetecting = VisionFaceDetector()) -> [ThumbnailCandidate] {
        guard project.width > 0, project.height > 0 else { return [] }
        let n = min(ThumbnailScoring.maxCount, max(1, count))
        let times = ThumbnailScoring.sampleTimes(start: start, duration: duration, samples: max(samples, n))
        let renderer = Renderer(project: project, assets: assets)
        var all: [ThumbnailCandidate] = []
        for t in times {
            let snapped = project.frameRate.snapped(t)
            guard let img = renderer.renderImage(t: snapped),
                  let c = ThumbnailScoring.candidate(time: snapped, image: img, faces: detector.faces(in: img)) else { continue }
            all.append(c)
        }
        // 近すぎる時刻の目安: 調べた間隔の 2 倍
        let gap = times.count > 1 ? (times[1] - times[0]) * 2 : 0
        return ThumbnailScoring.selectTop(all, count: n, minGap: gap)
    }

    /// 候補のコマを 1280×720 の画像として `folder` に書く。ファイル名は `<base>_candidate_01_t12.34s.<ext>`(点数の高い順)。書いた URL を返す。
    @discardableResult
    public static func write(_ candidates: [ThumbnailCandidate], project: Project, assets: RenderAssets = RenderAssets(),
                             baseName: String, format: StillFormat = .png, to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (i, c) in candidates.enumerated() {
            let name = String(format: "%@_candidate_%02d_t%.2fs.%@", baseName, i + 1, c.time, format.fileExtension)
            let url = folder.appendingPathComponent(name)
            try ThumbnailExporter.write(project: project, assets: assets, at: c.time, format: format, to: url)
            urls.append(url)
        }
        return urls
    }
}
