import Foundation
import MovieCutCore

/// オブジェクトトラッキングの実行セッション(キャンセル旗)。追跡ループ(別スレッド)から読む。
final class ObjectTrackingSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledFlag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelledFlag }
    func cancel() { lock.lock(); cancelledFlag = true; lock.unlock() }
}

/// オブジェクトトラッキング(W3-03 / 監査 #53)の実行まわり。計算は MovieCutCore(`ObjectTracking`)、
/// ここは非同期実行・進捗・キャンセル・Undo だけ。従来の「動きに追従させる」(`ProjectModel+Motion`)は
/// そのまま残し、こちらは開始矩形の指定・大きさの追従・結果の保存・ぼかし追従までを含む拡張版。
extension ProjectModel {
    static let objectTrackingUndoName = "対象に追従させる"

    /// 追従できる(位置を持つ映像系クリップで、下に追跡元の映像・画像がある)。
    func canObjectTrack(_ c: Clip) -> Bool {
        ObjectTracking.canFollow(c) && ObjectTracking.sourceClip(for: c.id, in: project) != nil
    }

    /// 追跡を中止する(実行中でなければ何もしない)。
    func cancelObjectTracking() { objectTrackingSession?.cancel() }

    /// 追従の開始矩形: ぼかし範囲クリップは自分自身の現在の矩形、それ以外は従来どおり中央の正方形。
    private func trackingStartRect(for c: Clip) -> CGRect {
        if c.type == .blur {
            let x = Animation.value(of: "x", in: c, at: 0), y = Animation.value(of: "y", in: c, at: 0)
            let w = Animation.value(of: "w", in: c, at: 0), h = Animation.value(of: "h", in: c, at: 0)
            return CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
        }
        return MotionTrack.startRect
    }

    /// 選んだクリップを、下の映像の対象に追従させる(位置+大きさ)。進捗は `objectTrackingProgress`。
    func runObjectTracking(clipId: String? = nil) {
        guard !isLocked, objectTrackingProgress == nil,
              let id = clipId ?? selectedClipId, let c = clip(id) else { return }
        guard let source = ObjectTracking.sourceClip(for: id, in: project) else {
            errorTitle = "追従できません"
            errorMessage = "位置を持つクリップを、映像・画像のレイヤーより上に置いてください。"
            return
        }
        let startRect = trackingStartRect(for: c)
        runTracking(source: source, start: c.start, duration: c.duration, startRect: startRect) { [weak self] track in
            guard let self else { return }
            _ = self.edit(Self.objectTrackingUndoName) { p in
                guard let loc = ClipEditing.locate(id, in: p) else { return }
                _ = ObjectTracking.apply(track: track, to: &p.tracks[loc.track].clips[loc.index])
            }
            if let lostAt = track.lostAt {
                self.statusText = String(format: "対象への追従を付けました（%.1f 秒で対象を見失ったため、そこまでで打ち切りました）", lostAt)
            } else {
                self.statusText = "対象への追従を付けました"
            }
        }
    }

    /// 選んだ映像・画像クリップの対象を追い、ぼかし範囲クリップを新規に作って追従させる。
    func addBlurFollower(clipId: String? = nil) {
        guard !isLocked, objectTrackingProgress == nil,
              let id = clipId ?? selectedClipId, let source = clip(id),
              source.type == .video || source.type == .image, source.src != nil else { return }
        runTracking(source: source, start: source.start, duration: source.duration, startRect: MotionTrack.startRect) { [weak self] track in
            guard let self else { return }
            var blur = ObjectTracking.makeBlurFollower(track: track, start: source.start, duration: source.duration)
            // 強さ・形は通常のぼかし範囲の既定に合わせる
            let tmpl = ClipEditing.makeBlurClip(at: source.start, project: self.project)
            blur.strength = tmpl.strength; blur.shape = tmpl.shape
            let newId = blur.id
            _ = self.edit("ぼかし範囲の追従を追加") { p in ClipEditing.appendToTopLayer(blur, in: &p) }
            self.selectedClipId = newId
            if let lostAt = track.lostAt {
                self.statusText = String(format: "ぼかし範囲の追従を付けました（%.1f 秒で対象を見失ったため、そこまでで打ち切りました）", lostAt)
            } else {
                self.statusText = "ぼかし範囲の追従を付けました"
            }
        }
    }

    /// 追跡の共通実行: 裏でコマを集め(進捗・キャンセル対応)、成功したら `onDone` を主スレッドで呼ぶ。
    private func runTracking(source: Clip, start: Double, duration: Double, startRect: CGRect,
                             onDone: @escaping (ObjectTrack) -> Void) {
        let project = self.project
        let assets = self.assets
        let session = ObjectTrackingSession()
        objectTrackingSession = session
        objectTrackingProgress = 0
        Task { @MainActor [weak self] in
            let run = await Task.detached(priority: .userInitiated) { () -> TrackingRun? in
                let renderer = Renderer(project: project, assets: assets)
                return ObjectTracking.collectRun(duration: duration, startRect: startRect, tracker: VisionRectTracker(),
                                              frame: { t in renderer.trackingFrame(of: source, at: start + t) },
                                              progress: { p in
                                                  DispatchQueue.main.async { [weak self] in
                                                      if self?.objectTrackingSession === session { self?.objectTrackingProgress = p }
                                                  }
                                              },
                                              shouldCancel: { session.isCancelled })
            }.value
            guard let self else { return }
            self.objectTrackingProgress = nil
            self.objectTrackingSession = nil
            if session.isCancelled {
                self.statusText = "追跡を中止しました"
                return
            }
            guard let run, let track = ObjectTracking.makeTrack(sourceClipId: source.id, startRect: startRect, rects: run.rects, lostAt: run.lostAt) else {
                self.errorTitle = "対象を追えませんでした"
                self.errorMessage = "映像の中央に、追いかけられる対象が見つかりませんでした。"
                return
            }
            onDone(track)
        }
    }

    /// 追従を取り消す(保存した追跡結果と追従キーを消す。1 回の Undo)。
    @discardableResult
    func clearObjectFollow(clipId: String? = nil) -> Bool {
        guard !isLocked, let id = clipId ?? selectedClipId, let c = clip(id), c.tracking != nil else { return false }
        let rel = min(max(currentTime - c.start, 0), c.duration)
        var changed = false
        setClipProperty({ changed = ObjectTracking.clearFollow(from: &$0, at: rel) }, name: "追従を消す", clipId: id)
        return changed
    }
}
