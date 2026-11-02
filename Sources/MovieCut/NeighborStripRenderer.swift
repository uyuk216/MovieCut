import Foundation
import CoreGraphics
import MovieCutCore

/// ドラッグ中の「移動先の前後のコマ」の帯を、背景スレッドで描く(古い要求は捨てて最新だけ描く。プレビューと同じ作り)。
/// `synchronous` はテスト用: その場で描いて、すぐ結果を渡す。
final class NeighborStripRenderer {
    private let queue = DispatchQueue(label: "moviecut.neighbor.strip", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: (project: Project, times: DragNeighborFrames.Times, assets: RenderAssets, seq: Int)?
    private var running = false
    private var seq = 0
    var synchronous = false
    /// 主スレッドで呼ぶ。描き終わった帯(古い要求の結果は渡さない)。
    var onImage: ((CGImage?) -> Void)?
    /// 描いた回数(検証用)と、捨てた要求の数。
    private(set) var renderCount = 0
    /// 最後に要求した 4 コマの時刻(検証用)。
    private(set) var lastTimes: DragNeighborFrames.Times?

    func request(project: Project, times: DragNeighborFrames.Times, assets: RenderAssets) {
        lastTimes = times
        lock.lock(); seq += 1; let mySeq = seq; lock.unlock()
        if synchronous {
            renderCount += 1
            onImage?(DragNeighborFrames.strip(project: project, assets: assets, times: times))
            return
        }
        lock.lock()
        pending = (project, times, assets, mySeq)
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { [weak self] in self?.loop() } }
    }

    /// 以後の結果を捨てる(ドラッグの終わり)。
    func cancel() {
        lock.lock(); seq += 1; pending = nil; lock.unlock()
    }

    private func loop() {
        while true {
            lock.lock()
            guard let job = pending else { running = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            let img = DragNeighborFrames.strip(project: job.project, assets: job.assets, times: job.times)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let current = job.seq == self.seq; self.lock.unlock()
                if current { self.renderCount += 1; self.onImage?(img) }
            }
        }
    }
}
