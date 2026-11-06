import Foundation
import CoreGraphics

// 立ち絵クリップのタイムライン上の扱い: 連動する声の一覧・声の長さに合わせる・表情の切り替わり(展開表示用)。
// どれも純粋な関数(値を返す)。UI は `ProjectModel+Tachie` から呼ぶ。

/// 展開した立ち絵クリップの「表情の切り替わり」1 件。
public struct TachieExpressionChange: Equatable, Sendable {
    public var time: Double            // 切り替わる時刻(プロジェクトの秒)
    public var voiceId: String
    public var tag: String?            // 表情名(nil = 通常)
    public init(time: Double, voiceId: String, tag: String?) { self.time = time; self.voiceId = voiceId; self.tag = tag }
}

public extension TachieEditing {
    /// 立ち絵クリップが連動する声クリップ(開始順)。`.none` は空。
    static func driverVoices(_ project: Project, clip: Clip) -> [Clip] {
        guard clip.type == .tachie else { return [] }
        let voices = project.allClips.filter { $0.type == .voice }.sorted { $0.start < $1.start }
        switch clip.mouthDriveOrDefault {
        case .none: return []
        case .all: return voices
        case .character(let id): return voices.filter { $0.charId == id }
        case .voiceClip(let id): return voices.filter { $0.id == id }
        }
    }

    /// 連動する声の全体の範囲(最初の頭〜最後の終わり)。声が無ければ nil。
    static func voiceSpan(_ project: Project, clip: Clip) -> (start: Double, end: Double)? {
        let v = driverVoices(project, clip: clip).filter { $0.duration > 0 }
        guard let s = v.map(\.start).min(), let e = v.map({ $0.start + $0.duration }).max(), e > s else { return nil }
        return (s, e)
    }

    /// 立ち絵クリップを、連動する声の範囲(最初の頭〜最後の終わり)に合わせる。
    /// 声が無い・立ち絵クリップでない・同じレイヤーの他のクリップと重なる・もう合っているときは変えない。
    static func fitToVoice(_ project: Project, clipId: String) -> Project {
        guard let loc = ClipEditing.locate(clipId, in: project) else { return project }
        let c = project.tracks[loc.track].clips[loc.index]
        guard c.type == .tachie, let span = voiceSpan(project, clip: c) else { return project }
        let eps = ClipEditing.timeEpsilon
        if abs(c.start - span.start) < eps && abs(c.duration - (span.end - span.start)) < eps { return project }
        let overlaps = project.tracks[loc.track].clips.contains { o in
            o.id != c.id && o.start < span.end - eps && o.start + o.duration > span.start + eps
        }
        guard !overlaps else { return project }
        var p = project
        p.tracks[loc.track].clips[loc.index].start = span.start
        p.tracks[loc.track].clips[loc.index].duration = span.end - span.start
        return p
    }

    /// 立ち絵クリップの区間で、連動する声ごとの表情タグの切り替わり(前の声と同じタグは省く)。
    static func expressionChanges(_ project: Project, clip: Clip) -> [TachieExpressionChange] {
        let end = clip.start + clip.duration
        var out: [TachieExpressionChange] = []
        var last: String?? = .none      // 最初は必ず出す
        for v in driverVoices(project, clip: clip) where v.start < end && v.start + v.duration > clip.start {
            let tag = ExpressionTag.split(v.text ?? "").tag
            if let l = last, l == tag { continue }
            out.append(TachieExpressionChange(time: v.start, voiceId: v.id, tag: tag))
            last = .some(tag)
        }
        return out
    }
}

public extension Renderer {
    /// 立ち絵クリップの、キャンバスの画素 `point` の絵が透明でないか(見えている絵に当たったか)。
    /// 絵が描けない(素材なし・声が出ていない speakingOnly)ときは nil。回転・左右上下反転を逆に当てて、描いた画像の画素を調べる。
    func tachieOpaque(_ c: Clip, at t: Double, point: CGPoint) -> Bool? {
        let W = Double(project.width), H = Double(project.height)
        let pose = ClipPose(c, at: t)
        let h = H * 0.6 * pose.scale
        guard h > 0, let (img, _) = tachieFrame(c, t: t, height: h), img.height > 0 else { return nil }
        let w = Double(img.width) * (h / Double(img.height))
        var lx = Double(point.x) - pose.x * W, ly = Double(point.y) - pose.y * H
        if pose.rotation != 0 {
            let a = -pose.rotation * .pi / 180
            let rx = lx * cos(a) - ly * sin(a), ry = lx * sin(a) + ly * cos(a)
            lx = rx; ly = ry
        }
        if c.flipHOrDefault { lx = -lx }
        if c.flipVOrDefault { ly = -ly }
        let u = (lx + w / 2) / w, v = (ly + h / 2) / h
        guard u >= 0, u < 1, v >= 0, v < 1 else { return false }
        let px = min(img.width - 1, Int(u * Double(img.width))), py = min(img.height - 1, Int(v * Double(img.height)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let ok = pixel.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            // 欲しい画素が (0,0) に来るようにずらして描く(CGContext は y 上向き)
            ctx.draw(img, in: CGRect(x: -px, y: -(img.height - 1 - py), width: img.width, height: img.height))
            return true
        }
        return ok ? pixel[3] > 8 : true
    }
}
