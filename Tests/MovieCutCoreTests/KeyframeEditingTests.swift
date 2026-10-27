import XCTest
@testable import MovieCutCore

final class KeyframeEditingTests: XCTestCase {
    let tol = KeyframeEditing.tolerance(fps: 60)

    private func imageClip(start: Double = 2, dur: Double = 4) -> Clip {
        var c = Clip(); c.id = "c"; c.type = .image; c.src = "/a.png"; c.start = start; c.duration = dur
        return c
    }

    func testToleranceIsHalfAFrame() {
        XCTAssertEqual(KeyframeEditing.tolerance(fps: 60), 1.0 / 120, accuracy: 1e-12)
        XCTAssertEqual(KeyframeEditing.tolerance(fps: 24), 1.0 / 48, accuracy: 1e-12)
    }

    func testToggleAddsKeyWithCurrentValueThenRemovesIt() {
        var c = imageClip(); c.x = 0.3
        XCTAssertEqual(KeyframeEditing.state(c, key: "x", at: 1, tolerance: tol), .none)
        XCTAssertTrue(KeyframeEditing.toggle(&c, key: "x", at: 1, tolerance: tol))
        XCTAssertEqual(c.keyframes["x"], [Keyframe(t: 1, v: 0.3)])          // いまの値で足す(最初のキーだけ = 一定)
        XCTAssertEqual(KeyframeEditing.state(c, key: "x", at: 1, tolerance: tol), .onKey)
        XCTAssertEqual(KeyframeEditing.state(c, key: "x", at: 1.0 + tol * 0.9, tolerance: tol), .onKey)
        XCTAssertEqual(KeyframeEditing.state(c, key: "x", at: 1.0 + tol * 1.1, tolerance: tol), .between)   // 半塗り
        // もう 1 つ足す: 2 つ目のキーの値は評価値(= 0.3)
        KeyframeEditing.toggle(&c, key: "x", at: 3, tolerance: tol)
        XCTAssertEqual(c.keyframes["x"]!.map(\.t), [1, 3])
        // 消す: 残りがあるので設定値は変わらない
        KeyframeEditing.toggle(&c, key: "x", at: 3.001, tolerance: tol)
        XCTAssertEqual(c.keyframes["x"]!.map(\.t), [1])
        // 最後の 1 つを消すと、その値が設定値になり、キーの表が消える
        c.keyframes["x"]![0].v = 0.9
        KeyframeEditing.toggle(&c, key: "x", at: 1, tolerance: tol)
        XCTAssertNil(c.keyframes["x"]); XCTAssertEqual(c.x, 0.9)
        XCTAssertTrue(c.keyframes.isEmpty)
    }

    func testToggleIgnoresKeysTheTypeLacks() {
        var a = Clip(); a.type = .audio
        XCTAssertFalse(KeyframeEditing.toggle(&a, key: "x", at: 0, tolerance: tol))
        var b = Clip(); b.type = .blur
        XCTAssertFalse(KeyframeEditing.toggle(&b, key: "rotation", at: 0, tolerance: tol))
        XCTAssertTrue(KeyframeEditing.toggle(&b, key: "strength", at: 0, tolerance: tol))
        var i = imageClip()
        XCTAssertFalse(KeyframeEditing.toggle(&i, key: "strength", at: 0, tolerance: tol))
    }

    func testSetValueUpdatesOrCreatesKeyWhenAnimated() {
        var c = imageClip()
        // キーが無い項目: 設定値を書く(従来どおり)
        KeyframeEditing.setValue(&c, key: "scale", 2, at: 1, tolerance: tol)
        XCTAssertEqual(c.scale, 2); XCTAssertTrue(c.keyframes.isEmpty)
        // キーを足す
        KeyframeEditing.toggle(&c, key: "scale", at: 0, tolerance: tol)
        KeyframeEditing.toggle(&c, key: "scale", at: 4, tolerance: tol)
        // キーの上で編集: そのキーを更新
        KeyframeEditing.setValue(&c, key: "scale", 3, at: 4.0, tolerance: tol)
        XCTAssertEqual(c.keyframes["scale"]!.map(\.v), [2, 3])
        XCTAssertEqual(c.scale, 2)                                           // 設定値は触らない
        // キーのない時刻で編集: 新しいキー
        KeyframeEditing.setValue(&c, key: "scale", 5, at: 2, tolerance: tol)
        XCTAssertEqual(c.keyframes["scale"]!.map(\.t), [0, 2, 4]); XCTAssertEqual(c.keyframes["scale"]!.map(\.v), [2, 5, 3])
        // 範囲に収める
        KeyframeEditing.setValue(&c, key: "scale", 999, at: 2, tolerance: tol)
        XCTAssertEqual(c.keyframes["scale"]![1].v, 20)
        KeyframeEditing.setValue(&c, key: "opacity", -4, at: 0, tolerance: tol)
        XCTAssertEqual(c.opacity, 0)
        // 回転 0 は未設定に戻る
        KeyframeEditing.setValue(&c, key: "rotation", 45, at: 0, tolerance: tol)
        KeyframeEditing.setValue(&c, key: "rotation", 0, at: 0, tolerance: tol)
        XCTAssertNil(c.rotation)
        // 位置は画面の外へも動かせる(キーのとき)
        KeyframeEditing.toggle(&c, key: "x", at: 0, tolerance: tol)
        KeyframeEditing.setValue(&c, key: "x", -1.5, at: 0, tolerance: tol)
        XCTAssertEqual(c.keyframes["x"]![0].v, -1.5)
    }

    func testNavigationBetweenKeys() {
        var c = imageClip()
        for t in [1.0, 2.0, 3.5] { KeyframeEditing.toggle(&c, key: "x", at: t, tolerance: tol) }
        KeyframeEditing.toggle(&c, key: "y", at: 2.5, tolerance: tol)
        XCTAssertEqual(KeyframeEditing.nextKeyTime(c, key: "x", after: 1, tolerance: tol), 2)
        XCTAssertEqual(KeyframeEditing.nextKeyTime(c, key: "x", after: 3.5, tolerance: tol), nil)
        XCTAssertEqual(KeyframeEditing.previousKeyTime(c, key: "x", before: 2, tolerance: tol), 1)
        XCTAssertNil(KeyframeEditing.previousKeyTime(c, key: "x", before: 1, tolerance: tol))
        XCTAssertEqual(KeyframeEditing.nextKeyTime(c, key: nil, after: 2, tolerance: tol), 2.5)      // 全項目
        XCTAssertEqual(KeyframeEditing.previousKeyTime(c, key: nil, before: 3.5, tolerance: tol), 2.5)
        XCTAssertEqual(KeyframeEditing.keyTimes(c), [1, 2, 2.5, 3.5])
        // 半コマ以内のずれは「同じ場所」とみなして飛ばす
        XCTAssertEqual(KeyframeEditing.nextKeyTime(c, key: "x", after: 1.0 - tol * 0.5, tolerance: tol), 2)
    }

    func testRemoveKeysAtTimeAndClearAll() {
        var c = imageClip(); c.x = 0.1
        KeyframeEditing.toggle(&c, key: "x", at: 0, tolerance: tol)
        KeyframeEditing.setValue(&c, key: "x", 0.2, at: 0, tolerance: tol)
        KeyframeEditing.setValue(&c, key: "x", 0.8, at: 4, tolerance: tol)
        KeyframeEditing.toggle(&c, key: "opacity", at: 4, tolerance: tol)
        XCTAssertEqual(KeyframeEditing.removeKeys(&c, at: 4, tolerance: tol), 2)
        XCTAssertEqual(c.keyframes["x"]!.map(\.t), [0]); XCTAssertNil(c.keyframes["opacity"])
        // すべて消す: 見た目が変わらないよう、その時刻の値が設定値になる
        KeyframeEditing.setValue(&c, key: "x", 0.9, at: 3, tolerance: tol)
        let at2 = Animation.value(of: "x", in: c, at: 2)
        XCTAssertEqual(KeyframeEditing.clearAll(&c, at: 2), 1)
        XCTAssertTrue(c.keyframes.isEmpty); XCTAssertEqual(c.x!, at2, accuracy: 1e-12)
        XCTAssertEqual(KeyframeEditing.clearAll(&c, at: 2), 0)
    }

    func testMoveKeys() {
        var c = imageClip()
        KeyframeEditing.toggle(&c, key: "x", at: 1, tolerance: tol)
        KeyframeEditing.toggle(&c, key: "y", at: 1, tolerance: tol)
        KeyframeEditing.toggle(&c, key: "x", at: 3, tolerance: tol)
        XCTAssertTrue(KeyframeEditing.moveKeys(&c, from: 1, to: 2, maxT: 4, tolerance: tol))
        XCTAssertEqual(c.keyframes["x"]!.map(\.t), [2, 3]); XCTAssertEqual(c.keyframes["y"]!.map(\.t), [2])
        // 行き先に別のキーがあれば置き換える
        XCTAssertTrue(KeyframeEditing.moveKeys(&c, from: 2, to: 3, maxT: 4, tolerance: tol))
        XCTAssertEqual(c.keyframes["x"]!.map(\.t), [3])
        // クリップの外へは出ない
        XCTAssertTrue(KeyframeEditing.moveKeys(&c, from: 3, to: 99, maxT: 4, tolerance: tol))
        XCTAssertEqual(c.keyframes["x"]!.map(\.t), [4])
        XCTAssertTrue(KeyframeEditing.moveKeys(&c, from: 4, to: -5, maxT: 4, tolerance: tol))
        XCTAssertEqual(c.keyframes["x"]!.map(\.t), [0])
        XCTAssertFalse(KeyframeEditing.moveKeys(&c, from: 2, to: 3, maxT: 4, tolerance: tol))      // そこにキーが無い
    }

    func testResetTransform() {
        var c = imageClip(); c.rotation = 30; c.flipH = true; c.crop = Crop(l: 0.1, t: 0, r: 0, b: 0); c.scale = 2; c.x = 0.2; c.opacity = 0.5
        c.keyframes["rotation"] = [Keyframe(t: 0, v: 5)]; c.keyframes["scale"] = [Keyframe(t: 0, v: 2)]; c.keyframes["x"] = [Keyframe(t: 0, v: 0.2)]
        XCTAssertTrue(KeyframeEditing.resetTransform(&c))
        XCTAssertNil(c.rotation); XCTAssertNil(c.flipH); XCTAssertNil(c.crop); XCTAssertEqual(c.scale, 1)
        XCTAssertEqual(c.x, 0.2); XCTAssertEqual(c.opacity, 0.5)        // 位置と不透明度は触らない
        XCTAssertEqual(Set(c.keyframes.keys), ["x"])
        XCTAssertFalse(KeyframeEditing.resetTransform(&c))              // もう戻すものがない
    }

    func testCropEdgeApplyRespectsLimits() {
        var c = imageClip()
        CropEdge.left.apply(0.3, to: &c); XCTAssertEqual(c.crop, Crop(l: 0.3, t: 0, r: 0, b: 0))
        CropEdge.right.apply(0.8, to: &c); XCTAssertEqual(c.crop!.r, 0.69, accuracy: 1e-12)    // 左+右 < 1
        CropEdge.top.apply(2, to: &c); XCTAssertEqual(c.crop!.t, 0.95)
        CropEdge.left.apply(.nan, to: &c); XCTAssertEqual(c.crop!.l, 0)
        for e in CropEdge.allCases { e.apply(0, to: &c) }
        XCTAssertNil(c.crop)                                                 // 全部 0 なら未設定
    }

    // MARK: プリセット

    func testPresetsWriteDocumentedKeys() {
        var c = imageClip(start: 1, dur: 5); c.x = 0.5; c.y = 0.5; c.scale = 1; c.opacity = 0.8
        XCTAssertTrue(AnimationPreset.zoomIn.apply(to: &c))
        XCTAssertEqual(c.keyframes["scale"], [Keyframe(t: 0, v: 1, ease: .easeInOut), Keyframe(t: 5, v: 1.5)])
        AnimationPreset.zoomOut.apply(to: &c)
        XCTAssertEqual(c.keyframes["scale"], [Keyframe(t: 0, v: 1.5, ease: .easeInOut), Keyframe(t: 5, v: 1)])
        AnimationPreset.slideFromLeft.apply(to: &c)
        XCTAssertEqual(c.keyframes["x"], [Keyframe(t: 0, v: -0.5, ease: .easeOut), Keyframe(t: 1, v: 0.5)])
        AnimationPreset.slideFromRight.apply(to: &c)
        XCTAssertEqual(c.keyframes["x"], [Keyframe(t: 0, v: 1.5, ease: .easeOut), Keyframe(t: 1, v: 0.5)])
        AnimationPreset.slideFromTop.apply(to: &c)
        XCTAssertEqual(c.keyframes["y"], [Keyframe(t: 0, v: -0.5, ease: .easeOut), Keyframe(t: 1, v: 0.5)])
        AnimationPreset.slideFromBottom.apply(to: &c)
        XCTAssertEqual(c.keyframes["y"], [Keyframe(t: 0, v: 1.5, ease: .easeOut), Keyframe(t: 1, v: 0.5)])
        AnimationPreset.spinIn.apply(to: &c)
        XCTAssertEqual(c.keyframes["rotation"], [Keyframe(t: 0, v: -180, ease: .easeOut), Keyframe(t: 1, v: 0)])
        XCTAssertEqual(c.keyframes["scale"], [Keyframe(t: 0, v: 0.2, ease: .easeOut), Keyframe(t: 1, v: 1)])
        XCTAssertEqual(c.keyframes["opacity"], [Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 0.8)])      // 元の不透明度へ
        AnimationPreset.kenBurns.apply(to: &c)
        XCTAssertEqual(c.keyframes["scale"]!.map(\.v), [1, 1.15])
        XCTAssertEqual(c.keyframes["x"]!.map(\.v), [0.5, 0.48]); XCTAssertEqual(c.keyframes["y"]!.map(\.v), [0.5, 0.49])
    }

    func testEntrancePresetsAreShortOnShortClips() {
        var c = imageClip(dur: 0.4)
        AnimationPreset.slideFromLeft.apply(to: &c)
        XCTAssertEqual(c.keyframes["x"]!.map(\.t), [0, 0.4])        // min(1 秒, 長さ)
    }

    func testPresetsOnlyForImageVideoText() {
        for t in [ClipType.blur, .audio, .voice] {
            var c = Clip(); c.type = t; c.duration = 3
            for p in AnimationPreset.allCases { XCTAssertFalse(p.apply(to: &c), "\(t) \(p)") }
            XCTAssertTrue(c.keyframes.isEmpty)
        }
        for t in [ClipType.image, .video, .text] {
            var c = Clip(); c.type = t; c.duration = 3
            for p in AnimationPreset.allCases { XCTAssertTrue(p.apply(to: &c)) }
        }
        XCTAssertEqual(AnimationPreset.allCases.count, 8)
        XCTAssertEqual(Set(AnimationPreset.allCases.map(\.title)).count, 8)
    }

    func testPresetKeepsOtherPropertiesKeys() {
        var c = imageClip(); c.keyframes["opacity"] = [Keyframe(t: 0, v: 0.5)]
        AnimationPreset.zoomIn.apply(to: &c)
        XCTAssertNotNil(c.keyframes["opacity"])
    }

    // MARK: クリップ編集への追従

    private func project(with clip: Clip) -> Project {
        var p = Project(); p.tracks = [Track(name: "t")]; p.tracks[0].clips = [clip]; return p
    }

    func testMovingAClipDoesNotChangeKeyTimes() {
        var c = imageClip(start: 1, dur: 4); c.keyframes["x"] = [Keyframe(t: 0, v: 0), Keyframe(t: 4, v: 1)]
        let r = ClipEditing.move(in: project(with: c), clipId: "c", deltaT: 3, targetTrackIndex: nil, playhead: 0, pps: 40, snapEnabled: false)
        let m = r.project.tracks[0].clips[0]
        XCTAssertEqual(m.start, 4); XCTAssertEqual(m.keyframes["x"]!.map(\.t), [0, 4])
    }

    func testTrimLeftShiftsKeysSoPictureStaysGlued() {
        var c = imageClip(start: 2, dur: 4); c.keyframes["x"] = [Keyframe(t: 0, v: 0), Keyframe(t: 4, v: 1)]
        // 頭を 1 秒進める → 同じ「絵の時刻」の値が変わらない
        let r = ClipEditing.trimLeft(in: project(with: c), clipId: "c", deltaT: 1, playhead: 0, pps: 40, snapEnabled: false)
        let t = r.project.tracks[0].clips[0]
        XCTAssertEqual(t.start, 3); XCTAssertEqual(t.duration, 3)
        XCTAssertEqual(t.keyframes["x"]!.map(\.t), [-1, 3])
        for pt in [3.0, 4.0, 5.5, 6.0] {
            XCTAssertEqual(Animation.value(of: "x", in: t, at: pt - t.start), Animation.value(of: "x", in: c, at: pt - c.start), accuracy: 1e-12, "\(pt)")
        }
        // 左へ広げる: 逆向きにずれる
        let r2 = ClipEditing.trimLeft(in: project(with: c), clipId: "c", deltaT: -1, playhead: 0, pps: 40, snapEnabled: false)
        XCTAssertEqual(r2.project.tracks[0].clips[0].keyframes["x"]!.map(\.t), [1, 5])
    }

    func testTrimRightLeavesKeys() {
        var c = imageClip(start: 2, dur: 4); c.keyframes["x"] = [Keyframe(t: 0, v: 0), Keyframe(t: 4, v: 1)]
        let r = ClipEditing.trimRight(in: project(with: c), clipId: "c", deltaT: -1, playhead: 0, pps: 40, snapEnabled: false)
        XCTAssertEqual(r.project.tracks[0].clips[0].keyframes["x"]!.map(\.t), [0, 4])
    }

    func testTrimBeforeShiftsKeys() throws {
        var c = imageClip(start: 2, dur: 4); c.keyframes["x"] = [Keyframe(t: 0, v: 0), Keyframe(t: 4, v: 1)]
        let p = try XCTUnwrap(ClipEditing.trimBefore(in: project(with: c), clipId: "c", at: 3))
        let t = p.tracks[0].clips[0]
        XCTAssertEqual(t.keyframes["x"]!.map(\.t), [-1, 3])
        XCTAssertEqual(Animation.value(of: "x", in: t, at: 0), Animation.value(of: "x", in: c, at: 1), accuracy: 1e-12)
    }

    func testSplitPartitionsKeysAndKeepsValuesContinuous() throws {
        var c = imageClip(start: 2, dur: 4)
        c.keyframes["x"] = [Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 1), Keyframe(t: 4, v: 0)]
        c.keyframes["opacity"] = [Keyframe(t: 3, v: 0.5)]
        let r = try XCTUnwrap(ClipEditing.split(in: project(with: c), clipId: "c", at: 3))   // 頭から 1 秒
        let l = r.project.tracks[0].clips[0], rt = r.project.tracks[0].clips[1]
        XCTAssertEqual(l.duration, 1); XCTAssertEqual(rt.start, 3)
        XCTAssertEqual(l.keyframes["x"]!.map(\.t), [0, 1]); XCTAssertEqual(l.keyframes["x"]!.map(\.v), [0, 0.5])
        XCTAssertEqual(rt.keyframes["x"]!.map(\.t), [0, 1, 3]); XCTAssertEqual(rt.keyframes["x"]!.map(\.v), [0.5, 1, 0])
        // 全部のキーが切れ目より後ろにある項目: 左は最初の値で一定、右はそのまま
        XCTAssertEqual(l.keyframes["opacity"]!.map(\.v), [0.5]); XCTAssertEqual(rt.keyframes["opacity"]!.first!.t, 0)
        // 切れ目の前後で、元と同じ値(直線の区間)
        for pt in [2.0, 2.5, 2.999] { XCTAssertEqual(Animation.value(of: "x", in: l, at: pt - l.start), Animation.value(of: "x", in: c, at: pt - c.start), accuracy: 1e-9) }
        for pt in [3.0, 4.0, 5.0, 5.9] { XCTAssertEqual(Animation.value(of: "x", in: rt, at: pt - rt.start), Animation.value(of: "x", in: c, at: pt - c.start), accuracy: 1e-9) }
        // 切れ目でぴったり連続
        XCTAssertEqual(Animation.value(of: "x", in: l, at: l.duration), Animation.value(of: "x", in: rt, at: 0), accuracy: 1e-12)
    }

    func testSplitWithoutKeysStaysWithoutKeys() throws {
        let r = try XCTUnwrap(ClipEditing.split(in: project(with: imageClip()), clipId: "c", at: 3))
        XCTAssertTrue(r.project.allClips.allSatisfy { $0.keyframes.isEmpty })
    }

    func testDuplicateCopiesKeys() throws {
        var c = imageClip(); c.keyframes["x"] = [Keyframe(t: 1, v: 0.3, ease: .easeOut)]
        let r = try XCTUnwrap(ClipEditing.duplicate(in: project(with: c), clipId: "c"))
        let copy = try XCTUnwrap(r.project.allClips.first { $0.id == r.newId })
        XCTAssertEqual(copy.keyframes, c.keyframes)
    }

    func testBlurRegionKeysFollowSplit() throws {
        var c = ClipEditing.makeBlurClip(at: 0, project: Project())
        c.id = "c"
        c.keyframes["x"] = [Keyframe(t: 0, v: 0.2), Keyframe(t: 3, v: 0.8)]
        let r = try XCTUnwrap(ClipEditing.split(in: project(with: c), clipId: "c", at: 1.5))
        XCTAssertEqual(r.project.tracks[0].clips[1].keyframes["x"]!.map(\.v), [0.5, 0.8])
    }

    // MARK: 直接操作の幾何

    func testTransformBoxCornersAndRotation() {
        let box = TransformBox(center: CGPoint(x: 100, y: 100), width: 40, height: 20, rotation: 0)
        XCTAssertEqual(box.corners, [CGPoint(x: 80, y: 90), CGPoint(x: 120, y: 90), CGPoint(x: 120, y: 110), CGPoint(x: 80, y: 110)])
        // 時計回り 90 度: 右上の角が右下へ
        let r = TransformBox(center: CGPoint(x: 100, y: 100), width: 40, height: 20, rotation: 90)
        let tr = r.corners[1]
        XCTAssertEqual(tr.x, 110, accuracy: 1e-9); XCTAssertEqual(tr.y, 120, accuracy: 1e-9)
        // 取っ手は上辺の外側(回転 0)
        XCTAssertEqual(box.rotationHandle.x, 100, accuracy: 1e-9); XCTAssertEqual(box.rotationHandle.y, 90 - TransformBox.rotationHandleOffset, accuracy: 1e-9)
        // 90 度回すと取っ手は右へ
        XCTAssertEqual(r.rotationHandle.x, 100 + 10 + TransformBox.rotationHandleOffset, accuracy: 1e-9)
    }

    func testHitTestPriority() {
        let box = TransformBox(center: CGPoint(x: 100, y: 100), width: 40, height: 20, rotation: 0)
        XCTAssertEqual(box.hitTest(CGPoint(x: 100, y: 100), radius: 6), .body)
        XCTAssertEqual(box.hitTest(CGPoint(x: 81, y: 91), radius: 6), .corner(0))
        XCTAssertEqual(box.hitTest(CGPoint(x: 119, y: 109), radius: 6), .corner(2))
        XCTAssertEqual(box.hitTest(box.rotationHandle, radius: 6), .rotation)
        XCTAssertEqual(box.hitTest(CGPoint(x: 300, y: 300), radius: 6), .none)
        XCTAssertEqual(box.hitTest(CGPoint(x: 100, y: 130), radius: 6), .none)
        // 回転していても、枠の中は本体・枠の外は none
        let r = TransformBox(center: CGPoint(x: 100, y: 100), width: 40, height: 20, rotation: 90)
        XCTAssertEqual(r.hitTest(CGPoint(x: 100, y: 115), radius: 3), .body)    // 回すと縦長になる
        XCTAssertEqual(r.hitTest(CGPoint(x: 115, y: 100), radius: 3), .none)
    }

    func testManipulationMath() {
        let c = CGPoint(x: 100, y: 100)
        XCTAssertEqual(TransformBox.scaleRatio(center: c, from: CGPoint(x: 120, y: 100), to: CGPoint(x: 160, y: 100)), 3, accuracy: 1e-12)
        XCTAssertEqual(TransformBox.scaleRatio(center: c, from: c, to: CGPoint(x: 5, y: 5)), 1)
        XCTAssertEqual(TransformBox.rotationDelta(center: c, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 150, y: 100)), 90, accuracy: 1e-9)    // 上 → 右 = 時計回り 90
        XCTAssertEqual(TransformBox.rotationDelta(center: c, from: CGPoint(x: 150, y: 100), to: CGPoint(x: 100, y: 50)), -90, accuracy: 1e-9)
        XCTAssertEqual(TransformBox.rotationDelta(center: c, from: CGPoint(x: 50, y: 99), to: CGPoint(x: 50, y: 101)), -2.2918, accuracy: 0.01)   // 左側を下へ = 反時計回り
        let m = DirectManipulation.moved(x: 0.5, y: 0.5, dx: 192, dy: -108, canvas: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(m.x, 0.6, accuracy: 1e-12); XCTAssertEqual(m.y, 0.4, accuracy: 1e-12)
        XCTAssertEqual(DirectManipulation.scaled(1, ratio: 2), 2)
        XCTAssertEqual(DirectManipulation.scaled(1, ratio: 1000), 20)
        XCTAssertEqual(DirectManipulation.rotated(10, delta: 22, snap: false), 32)
        XCTAssertEqual(DirectManipulation.rotated(10, delta: 22, snap: true), 30)
    }
}

final class DirectManipulationApplyTests: XCTestCase {
    let tol = KeyframeEditing.tolerance(fps: 60)
    let canvas = CGSize(width: 1000, height: 500)

    private func clip() -> Clip {
        var c = Clip(); c.type = .image; c.x = 0.5; c.y = 0.5; c.scale = 1; c.duration = 4; return c
    }

    func testMoveWritesStaticValuesWhenNotAnimated() {
        let r = DirectManipulation.apply(.move, to: clip(), at: 1, tolerance: tol, from: CGPoint(x: 500, y: 250), to: CGPoint(x: 600, y: 200), canvas: canvas)
        XCTAssertEqual(r.x!, 0.6, accuracy: 1e-12); XCTAssertEqual(r.y!, 0.4, accuracy: 1e-12)
        XCTAssertTrue(r.keyframes.isEmpty)
    }

    func testMoveUpdatesOrCreatesKeysWhenAnimated() {
        var c = clip()
        c.keyframes["x"] = [Keyframe(t: 0, v: 0.2), Keyframe(t: 2, v: 0.8)]
        // t = 1 にキーは無い → 新しいキーができる(現在値 0.5 から +100px = +0.1)
        let r = DirectManipulation.apply(.move, to: c, at: 1, tolerance: tol, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), canvas: canvas)
        XCTAssertEqual(r.keyframes["x"]!.map(\.t), [0, 1, 2]); XCTAssertEqual(r.keyframes["x"]![1].v, 0.6, accuracy: 1e-9)
        XCTAssertEqual(r.x, 0.5)                                           // 設定値は触らない
        XCTAssertNil(r.keyframes["y"]); XCTAssertEqual(r.y!, 0.5, accuracy: 1e-12)    // 動かない項目は設定値を書く
        // キーの上なら、そのキーを更新(増えない)
        let r2 = DirectManipulation.apply(.move, to: c, at: 2, tolerance: tol, from: .zero, to: CGPoint(x: -100, y: 0), canvas: canvas)
        XCTAssertEqual(r2.keyframes["x"]!.count, 2); XCTAssertEqual(r2.keyframes["x"]![1].v, 0.7, accuracy: 1e-9)
    }

    func testScaleAndRotateFromHandles() {
        var c = clip(); c.keyframes["scale"] = [Keyframe(t: 0, v: 1)]
        let s = DirectManipulation.apply(.scale, to: c, at: 1, tolerance: tol, from: CGPoint(x: 600, y: 250), to: CGPoint(x: 700, y: 250), canvas: canvas)   // 中心 (500, 250): 100 → 200
        XCTAssertEqual(s.keyframes["scale"]!.map(\.v), [1, 2])
        let r = DirectManipulation.apply(.rotate, to: clip(), at: 0, tolerance: tol, from: CGPoint(x: 500, y: 100), to: CGPoint(x: 650, y: 250), canvas: canvas)   // 上 → 右
        XCTAssertEqual(r.rotation!, 90, accuracy: 1e-9)
        var rotated = clip(); rotated.rotation = 10
        let snapped = DirectManipulation.apply(.rotate, to: rotated, at: 0, tolerance: tol, from: CGPoint(x: 500, y: 100), to: CGPoint(x: 650, y: 250), canvas: canvas, snapRotation: true)
        XCTAssertEqual(snapped.rotation!, 105, accuracy: 1e-9)
    }

    func testBoxFromClip() {
        var c = clip(); c.rotation = 30; c.keyframes["x"] = [Keyframe(t: 0, v: 0.2), Keyframe(t: 2, v: 0.6)]
        let b = TransformBox.make(clip: c, objectSize: CGSize(width: 100, height: 50), at: 1, canvas: canvas)
        XCTAssertEqual(b.center.x, 400, accuracy: 1e-9); XCTAssertEqual(b.center.y, 250, accuracy: 1e-9)
        XCTAssertEqual(b.rotation, 30); XCTAssertEqual(b.width, 100)
    }
}
