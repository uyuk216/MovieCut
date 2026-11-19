import Foundation
import CoreGraphics
import MovieCutCore

/// オブジェクトマスク(Premiere の AI オブジェクトマスクのローカル等価)の実行まわり。
/// 計算は MovieCutCore(`ObjectMask` / `ObjectMaskPropagation` / Vision 前景インスタンス検出)、
/// ここは非同期実行・進捗・キャンセル・Undo・プレビューのクリック指定だけ。
/// 流れ: 種コマで対象を選ぶ(クリック = 点を含む最小のインスタンス / 矩形 = IoU 最大)
/// → 輪郭を種マスクとして切り抜く → `ObjectTracking.collect`(Vision 矩形追跡)で
/// 種時刻から前後へ伝播 → 1 秒ごとに再検出して輪郭を付け足す → `Clip.objectMask` に保存。
extension ProjectModel {
    nonisolated static let objectMaskUndoName = "オブジェクトマスクの変更"
    static let objectMaskCreateUndoName = "オブジェクトマスクを作成"

    // MARK: 付け外し・項目変更(形のマスクと同じ作法。どれも 1 回の Undo)

    func setObjectMask(_ mask: ObjectMask?, clipId: String? = nil, name: String = ProjectModel.objectMaskUndoName) {
        setClipProperty({ $0.objectMask = mask }, name: name, clipId: clipId)
    }

    /// 1 項目だけ変える(マスクが無ければ何もしない)。
    func setObjectMaskField(clipId: String, name: String = ProjectModel.objectMaskUndoName, _ change: @escaping (inout ObjectMask) -> Void) {
        setClipProperty({ c in
            guard var om = c.objectMask else { return }
            change(&om)
            c.objectMask = om
        }, name: name, clipId: clipId)
    }

    /// スライダーのドラッグ中(`beginGesture` 〜 `commitGesture`)。形のマスクの `liveMaskField` と同じ作法。
    func liveObjectMaskField(clipId: String, _ change: @escaping (inout ObjectMask) -> Void) {
        guard !isLocked, let c = clip(clipId), c.objectMask != nil else { return }
        var p = gestureBase ?? project
        guard let loc = ClipEditing.locate(c.id, in: p), var om = p.tracks[loc.track].clips[loc.index].objectMask else { return }
        change(&om)
        p.tracks[loc.track].clips[loc.index].objectMask = om
        if gestureBase != nil { updateGesture(p) } else if p != project { edit(Self.objectMaskUndoName) { $0 = p } }
    }

    // MARK: 作成の入口

    /// オブジェクトマスクを作れる(自分の映像・画像を持つクリップだけ。輪郭の種が要るため)。
    func canCreateObjectMask(_ c: Clip) -> Bool {
        (c.type == .video || c.type == .image) && c.src != nil
    }

    /// 矩形指定の下書きを 1 項目変える(下書きは保存しないので Undo に載せない)。
    func setObjectMaskSeedRectField(_ change: (inout TrackRect) -> Void) {
        var r = objectMaskSeedRect
        change(&r)
        objectMaskSeedRect = r.normalized
        objectWillChange.send()
    }

    /// 矩形指定で作成する(下書きの矩形と IoU が最大の対象を選ぶ)。
    func createObjectMaskFromSeedRect(clipId: String? = nil) {
        guard let id = clipId ?? selectedClipId else { return }
        let rect = objectMaskSeedRect
        runObjectMaskCreation(clipId: id) { instances in
            ObjectMaskPropagation.pickInstance(overlapping: rect, instances: instances.map(\.rect)).map { instances[$0] }
        }
    }

    /// プレビューのクリック指定を待つ状態にする。次のプレビューのクリックが種になる。
    func armObjectMaskPicking(clipId: String) {
        guard !isLocked, objectMaskProgress == nil, let c = clip(clipId), canCreateObjectMask(c) else { return }
        objectMaskPickingClipId = clipId
        statusText = "プレビューで対象をクリックしてください"
    }

    func cancelObjectMaskPicking() { objectMaskPickingClipId = nil }

    /// プレビューでクリックした点(キャンバスに対する割合・左上原点)から作成する。
    func seedObjectMask(clipId: String, atNormalizedPoint point: CGPoint) {
        runObjectMaskCreation(clipId: clipId) { instances in
            ObjectMaskPropagation.pickInstance(at: point, instances: instances.map(\.rect)).map { instances[$0] }
        }
    }

    /// 作成を中止する(実行中でなければ何もしない)。
    func cancelObjectMaskCreation() { objectMaskSession?.cancel() }

    // MARK: 作成の実行(進捗・キャンセル対応)

    private func runObjectMaskCreation(clipId: String, pick: @escaping ([ForegroundInstance]) -> ForegroundInstance?) {
        guard !isLocked, objectMaskProgress == nil, let clip = clip(clipId) else { return }
        guard canCreateObjectMask(clip) else {
            errorTitle = "オブジェクトマスクを作成できません"
            errorMessage = "映像・画像のクリップを選んでください。"
            return
        }
        let seedTime = min(max(currentTime - clip.start, 0), clip.duration)
        let previous = clip.objectMask   // 作り直しのときは羽根・反転を引き継ぐ
        let project = self.project
        let assets = self.assets
        let session = ObjectTrackingSession()
        objectMaskSession = session
        objectMaskProgress = 0
        Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> (mask: ObjectMask?, cancelled: Bool) in
                let renderer = Renderer(project: project, assets: assets)
                func report(_ p: Double) {
                    DispatchQueue.main.async { [weak self] in
                        if self?.objectMaskSession === session { self?.objectMaskProgress = p }
                    }
                }
                // 種コマで対象を選ぶ
                guard let frame = renderer.trackingFrame(of: clip, at: clip.start + seedTime),
                      let instances = try? VisionForegroundInstanceDetector().instances(for: frame),
                      let picked = pick(instances) else { return (nil, false) }
                let seedPNG = ObjectMaskImage.cropped(picked.mask, toNormalized: picked.rect)
                    .flatMap { ObjectMaskImage.pngBase64(of: $0) }
                // 追跡: 種時刻から終わりへ(進捗 0〜0.6)と、種時刻から頭へ(0.6〜0.85)
                let rate = ObjectTracking.sampleRate
                let forward = ObjectTracking.collect(duration: clip.duration - seedTime, startRect: picked.rect.cgRect,
                                                     tracker: VisionRectTracker(),
                                                     frame: { t in renderer.trackingFrame(of: clip, at: clip.start + seedTime + t) },
                                                     progress: { report(0.6 * $0) },
                                                     shouldCancel: { session.isCancelled })
                guard let forward else { return (nil, true) }
                var samples = forward.enumerated().map { k, r in
                    TrackSample(t: seedTime + Double(k) / rate, rect: r.map { TrackRect($0) })
                }
                if seedTime > 0.05 {
                    let backward = ObjectTracking.collect(duration: seedTime, startRect: picked.rect.cgRect,
                                                          tracker: VisionRectTracker(),
                                                          frame: { t in renderer.trackingFrame(of: clip, at: clip.start + seedTime - t) },
                                                          progress: { report(0.6 + 0.25 * $0) },
                                                          shouldCancel: { session.isCancelled })
                    guard let backward else { return (nil, true) }
                    for (k, r) in backward.enumerated() where k > 0 {
                        samples.append(TrackSample(t: seedTime - Double(k) / rate, rect: r.map { TrackRect($0) }))
                    }
                }
                samples.sort { $0.t < $1.t }
                let track = ObjectTrack(sourceClipId: clip.id, startRect: picked.rect, samples: samples)
                guard var om = ObjectMaskPropagation.build(sourceClipId: clip.id, seedTime: seedTime,
                                                           seedRect: picked.rect, seedMaskBase64: seedPNG,
                                                           track: track,
                                                           feather: previous?.feather ?? 0,
                                                           invert: previous?.invert ?? false) else { return (nil, false) }
                // 1 秒ごとの再検出: 追跡矩形に一番合う対象の輪郭を、その時刻のサンプルへ付け足す
                if clip.duration >= 1 {
                    var t = 0.0
                    while t <= clip.duration {
                        defer { t += 1 }
                        if session.isCancelled { return (nil, true) }
                        if abs(t - seedTime) < 0.5 { continue }
                        guard let f = renderer.trackingFrame(of: clip, at: clip.start + t),
                              let found = try? VisionForegroundInstanceDetector().instances(for: f),
                              let rect = om.rect(at: t),
                              let idx = ObjectMaskPropagation.pickInstance(overlapping: rect, instances: found.map(\.rect)),
                              let crop = ObjectMaskImage.cropped(found[idx].mask, toNormalized: found[idx].rect),
                              let png = ObjectMaskImage.pngBase64(of: crop) else { continue }
                        ObjectMaskPropagation.attachMask(png, at: t, to: &om)
                    }
                }
                report(1)
                return (om, false)
            }.value
            guard let self else { return }
            self.objectMaskProgress = nil
            self.objectMaskSession = nil
            if outcome.cancelled {
                self.statusText = "オブジェクトマスクの作成を中止しました"
                return
            }
            guard let om = outcome.mask else {
                self.errorTitle = "オブジェクトマスクを作成できませんでした"
                self.errorMessage = "対象が見つかりませんでした(人物や物がはっきり写っているコマで試してください)。"
                return
            }
            _ = self.edit(Self.objectMaskCreateUndoName) { p in
                guard let loc = ClipEditing.locate(clipId, in: p) else { return }
                p.tracks[loc.track].clips[loc.index].objectMask = om
            }
            self.statusText = "オブジェクトマスクを作成しました"
        }
    }
}
