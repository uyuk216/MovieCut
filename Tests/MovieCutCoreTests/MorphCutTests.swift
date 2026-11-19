import XCTest
import CoreGraphics
@testable import MovieCutCore

/// モーフカット: 種別登録、状態、パラメータ、編集、フォールバック判定、フロー量、顔の位置合わせ、隣接の探索、画素。
final class MorphCutTests: XCTestCase {
    // MARK: ヘルパー

    /// 暗い市松の背景に明るい四角(230)を x = squareX、縦は中央に置いた画像。
    func scene(w: Int, h: Int, squareX: Int, size: Int = 40) -> CGImage {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let sy = (h - size) / 2
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                var v = UInt8(30 + ((x / 4 + y / 4) % 2) * 10)
                if x >= squareX && x < squareX + size && y >= sy && y < sy + size { v = 230 }
                px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
            }
        }
        let ctx = px.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)! }
        return ctx.makeImage()!
    }

    /// 単色(グレー)の画像。
    func solid(w: Int, h: Int, gray: UInt8) -> CGImage {
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        var px = [UInt8](repeating: gray, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4 + 3] = 255 }
        let ctx = px.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)! }
        return ctx.makeImage()!
    }

    func green(_ img: CGImage, _ x: Int, _ y: Int) -> Int {
        let bm = OpticalFlowInterpolator.bitmap(of: img, width: img.width, height: img.height)!
        return Int(bm.bytes[(y * img.width + x) * 4 + 1])
    }

    /// 明るい四角(緑 > 150)の左端(行は中央)
    func squareLeft(_ img: CGImage) -> Int? {
        let w = img.width, h = img.height
        guard let bm = OpticalFlowInterpolator.bitmap(of: img, width: w, height: h) else { return nil }
        let y = h / 2
        for x in 0..<w where bm.bytes[(y * w + x) * 4 + 1] > 150 { return x }
        return nil
    }

    func clip(_ id: String, _ type: ClipType = .video, start: Double, duration: Double) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.start = start; c.duration = duration
        return c
    }

    func morphClip(tin: Transition? = nil, tout: Transition? = nil) -> Clip {
        var c = clip("m", .image, start: 10, duration: 4)
        c.transitionIn = tin; c.transitionOut = tout
        return c
    }

    // MARK: 1. 種別登録

    func testKindRegistration() {
        XCTAssertEqual(TransitionKind(rawValue: "morphCut"), .morphCut)
        XCTAssertEqual(Transition(kind: "morphCut").known, .morphCut)
        XCTAssertEqual(TransitionKind.morphCut.label, "モーフカット")
        XCTAssertEqual(TransitionKind.morphCut.category, .effect)
        for k in TransitionKind.allCases { XCTAssertEqual(k.isMorphCut, k == .morphCut) }
        XCTAssertEqual(TransitionKind.allCases.count, 44)
    }

    // MARK: 2. 状態

    func testInState() {
        let c = morphClip(tin: Transition(.morphCut, duration: 1, ease: .linear))
        let s0 = TransitionMath.apply(c, t: 10)
        XCTAssertEqual(s0.morphCut, MorphCutVisualState(isIn: true, weight: 0))
        XCTAssertFalse(s0.isIdentity)
        XCTAssertEqual(s0.opacityMul, 1)
        XCTAssertEqual(TransitionMath.apply(c, t: 10.5).morphCut?.weight ?? -1, 0.5, accuracy: 1e-9)
        let after = TransitionMath.apply(c, t: 11.5)
        XCTAssertTrue(after.isIdentity)
        XCTAssertNil(after.morphCut)
    }

    func testOutState() {
        let c = morphClip(tout: Transition(.morphCut, duration: 1, ease: .linear))
        XCTAssertNil(TransitionMath.apply(c, t: 12).morphCut)
        let s = TransitionMath.apply(c, t: 13.75)
        XCTAssertEqual(s.morphCut?.isIn, false)
        XCTAssertEqual(s.morphCut?.weight ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertEqual(s.opacityMul, 1)
    }

    // MARK: 3. パラメータ

    func testParameters() {
        let d = Transition(.morphCut).morphParameters
        XCTAssertEqual(d.strength, 1)
        XCTAssertTrue(d.facePriority)
        let p = Transition(kind: "morphCut", params: .object(["morphStrength": .number(0.4), "morphFace": .bool(false)])).morphParameters
        XCTAssertEqual(p.strength, 0.4)
        XCTAssertFalse(p.facePriority)
        let n = Transition(kind: "morphCut", params: .object(["morphFace": .number(0)])).morphParameters
        XCTAssertFalse(n.facePriority)
        XCTAssertEqual(MorphCutParameters.clampedStrength(7), 1)
        XCTAssertEqual(MorphCutParameters.clampedStrength(-2), 0)
        XCTAssertEqual(MorphCutParameters.clampedStrength(.nan), 1)
        XCTAssertEqual(MorphCutParameters(strength: 9).strength, 1)
    }

    // MARK: 4. 編集

    func testEditing() {
        var c = morphClip()
        XCTAssertTrue(TransitionEditing.setKind(&c, edge: .in, kind: .morphCut))
        XCTAssertTrue(TransitionEditing.setMorphStrength(&c, edge: .in, 0.3))
        XCTAssertEqual(c.transitionIn?.morphParameters.strength, 0.3)
        XCTAssertFalse(TransitionEditing.setMorphStrength(&c, edge: .in, 0.3))
        XCTAssertTrue(TransitionEditing.setMorphStrength(&c, edge: .in, 1))
        XCTAssertNil(c.transitionIn?.params)
        XCTAssertTrue(TransitionEditing.setMorphFacePriority(&c, edge: .in, false))
        XCTAssertEqual(c.transitionIn?.morphParameters.facePriority, false)
        XCTAssertTrue(TransitionEditing.setMorphFacePriority(&c, edge: .in, true))
        XCTAssertNil(c.transitionIn?.params)
    }

    func testEditingIgnoresOtherKinds() {
        var c = morphClip()
        _ = TransitionEditing.setKind(&c, edge: .in, kind: .fade)
        let before = c
        XCTAssertFalse(TransitionEditing.setMorphStrength(&c, edge: .in, 0.3))
        XCTAssertFalse(TransitionEditing.setMorphFacePriority(&c, edge: .in, false))
        XCTAssertEqual(c, before)
    }

    func testCodableRoundTrip() throws {
        let t = Transition(kind: "morphCut", duration: 0.8, ease: .linear,
                           params: .object(["morphStrength": .number(0.4), "morphFace": .bool(false)]))
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Transition.self, from: data)
        XCTAssertEqual(back, t)
        XCTAssertEqual(back.morphParameters, MorphCutParameters(strength: 0.4, facePriority: false))
    }

    // MARK: 5. フォールバック判定

    func testStrategyMatrix() {
        func s(_ n: Bool = true, _ sz: Bool = true, _ f: Bool = true, _ l: Double? = 0.05, _ m: Double? = 0.05) -> MorphCutStrategy {
            MorphCut.strategy(hasNeighbor: n, sizeMatches: sz, flowAvailable: f, lumaDifference: l, meanMotionFraction: m)
        }
        XCTAssertEqual(s(false), .none)
        XCTAssertEqual(s(true, false), .none)
        XCTAssertEqual(s(true, true, false), .crossDissolve)
        XCTAssertEqual(s(true, true, true, 0.5), .crossDissolve)
        XCTAssertEqual(s(true, true, true, 0.05, 0.9), .crossDissolve)
        XCTAssertEqual(s(true, true, true, 0.05, nil), .crossDissolve)
        XCTAssertEqual(s(), .morph)
    }

    // MARK: 6. フロー量

    func testMeanMotionFraction() {
        XCTAssertEqual(MorphCut.meanMotionFraction(.constant(width: 10, height: 10, dx: 3, dy: 4)) ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(MorphCut.meanMotionFraction(.constant(width: 10, height: 10, dx: 0, dy: 0)) ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(MorphCut.meanMotionFraction(FlowField(width: 0, height: 0, data: [])))
    }

    // MARK: 7. 顔の位置合わせ

    func face(_ cx: Double, _ cy: Double, _ w: Double = 0.1, _ h: Double = 0.1) -> CGRect {
        CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    func testFaceAlignment() {
        let d = MorphCut.faceAlignment(facesA: [face(0.4, 0.5)], facesB: [face(0.6, 0.5)], facePriority: true)
        XCTAssertEqual(d?.dx ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(d?.dy ?? -1, 0, accuracy: 1e-9)
        // 大きなずれ(別場面とみなす手前)は ±0.2 に収める
        let c = MorphCut.faceAlignment(facesA: [face(0.3, 0.5)], facesB: [face(0.7, 0.5)], facePriority: true)
        XCTAssertEqual(c?.dx ?? -1, 0.2, accuracy: 1e-9)
        let c2 = MorphCut.faceAlignment(facesA: [face(0.7, 0.5)], facesB: [face(0.3, 0.5)], facePriority: true)
        XCTAssertEqual(c2?.dx ?? 1, -0.2, accuracy: 1e-9)
        XCTAssertNil(MorphCut.faceAlignment(facesA: [], facesB: [face(0.6, 0.5)], facePriority: true))
        XCTAssertNil(MorphCut.faceAlignment(facesA: [face(0.4, 0.5)], facesB: [], facePriority: true))
        XCTAssertNil(MorphCut.faceAlignment(facesA: [face(0.4, 0.5)], facesB: [face(0.6, 0.5)], facePriority: false))
        // 複数顔は面積最大の顔どうし
        let m = MorphCut.faceAlignment(facesA: [face(0.1, 0.1, 0.05, 0.05), face(0.4, 0.5, 0.2, 0.2)],
                                       facesB: [face(0.9, 0.9, 0.05, 0.05), face(0.5, 0.5, 0.2, 0.2)], facePriority: true)
        XCTAssertEqual(m?.dx ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(m?.dy ?? -1, 0, accuracy: 1e-9)
    }

    func testFaceShiftTooLarge() {
        XCTAssertTrue(MorphCut.faceShiftTooLarge(facesA: [face(0.2, 0.5)], facesB: [face(0.8, 0.5)]))
        XCTAssertFalse(MorphCut.faceShiftTooLarge(facesA: [face(0.4, 0.5)], facesB: [face(0.6, 0.5)]))
        XCTAssertFalse(MorphCut.faceShiftTooLarge(facesA: [], facesB: [face(0.6, 0.5)]))
    }

    // MARK: 8. 隣接クリップ

    func testNeighborIndex() {
        let clips = [clip("a", start: 0, duration: 5), clip("b", start: 5, duration: 5), clip("c", start: 10, duration: 5)]
        XCTAssertEqual(MorphCut.neighborIndex(clips: clips, for: "b", edge: .in), 0)
        XCTAssertEqual(MorphCut.neighborIndex(clips: clips, for: "b", edge: .out), 2)
        XCTAssertNil(MorphCut.neighborIndex(clips: clips, for: "a", edge: .in))
        XCTAssertNil(MorphCut.neighborIndex(clips: clips, for: "c", edge: .out))
        XCTAssertNil(MorphCut.neighborIndex(clips: clips, for: "zzz", edge: .in))
    }

    func testNeighborGapAndType() {
        let far = [clip("a", start: 0, duration: 5), clip("b", start: 6, duration: 5)]
        XCTAssertNil(MorphCut.neighborIndex(clips: far, for: "b", edge: .in))
        XCTAssertNil(MorphCut.neighborIndex(clips: far, for: "a", edge: .out))
        let near = [clip("a", .image, start: 0, duration: 5), clip("b", start: 5.4, duration: 5)]
        XCTAssertEqual(MorphCut.neighborIndex(clips: near, for: "b", edge: .in), 0)
        let aud = [clip("a", .audio, start: 0, duration: 5), clip("b", start: 5, duration: 5), clip("c", .audio, start: 10, duration: 5)]
        XCTAssertNil(MorphCut.neighborIndex(clips: aud, for: "b", edge: .in))
        XCTAssertNil(MorphCut.neighborIndex(clips: aud, for: "b", edge: .out))
    }

    // MARK: 9. 画素

    let none = MorphCutParameters(strength: 1, facePriority: false)

    func testEndpointsAreSameInstance() {
        let a = scene(w: 200, h: 100, squareX: 40), b = scene(w: 200, h: 100, squareX: 80)
        XCTAssertTrue(MorphCut.morphImage(a, b, weight: 0, flow: nil, facesA: [], facesB: [], params: none) === a)
        XCTAssertTrue(MorphCut.morphImage(a, b, weight: 1, flow: nil, facesA: [], facesB: [], params: none) === b)
    }

    func testSizeMismatchIsNil() {
        let a = scene(w: 200, h: 100, squareX: 40), b = scene(w: 100, h: 100, squareX: 40)
        XCTAssertNil(MorphCut.morphImage(a, b, weight: 0.5, flow: nil, facesA: [], facesB: [], params: none))
    }

    func testNilFlowFallsBackToDissolve() {
        let a = scene(w: 200, h: 100, squareX: 40), b = scene(w: 200, h: 100, squareX: 100)
        let r = MorphCut.morphImage(a, b, weight: 0.3, flow: nil, facesA: [], facesB: [], params: none)!
        let d = FrameBlend.mix(a, b, weight: 0.3)!
        for (x, y) in [(10, 10), (50, 50), (110, 50), (150, 30)] { XCTAssertEqual(green(r, x, y), green(d, x, y)) }
    }

    func testLargeLumaDifferenceFallsBackToDissolve() {
        let a = solid(w: 100, h: 100, gray: 0), b = solid(w: 100, h: 100, gray: 255)
        let r = MorphCut.morphImage(a, b, weight: 0.5, flow: .constant(width: 10, height: 10, dx: 0, dy: 0), facesA: [], facesB: [], params: none)!
        XCTAssertEqual(Double(green(r, 50, 50)), 127.5, accuracy: 3)
    }

    func testKnownFlowMovesSquare() {
        // 400×200 の四角が x=100 → 140(40 画素)。フローのグリッドは 100×50 なので dx = 10
        let a = scene(w: 400, h: 200, squareX: 100), b = scene(w: 400, h: 200, squareX: 140)
        let flow = FlowField.constant(width: 100, height: 50, dx: 10, dy: 0)
        let r = MorphCut.morphImage(a, b, weight: 0.5, flow: flow, facesA: [], facesB: [], params: none)!
        let left = squareLeft(r)
        XCTAssertNotNil(left)
        XCTAssertEqual(Double(left ?? 0), 120, accuracy: 4)
    }

    func testExcessiveFlowFallsBackToDissolve() {
        let a = scene(w: 400, h: 200, squareX: 100), b = scene(w: 400, h: 200, squareX: 140)
        let flow = FlowField.constant(width: 100, height: 50, dx: 90, dy: 0)   // 幅の 0.9 倍
        let r = MorphCut.morphImage(a, b, weight: 0.5, flow: flow, facesA: [], facesB: [], params: none)!
        // 元の位置(A だけの領域)に半分の明るさの残像
        let g = green(r, 105, 100)
        XCTAssertTrue((100...160).contains(g), "残像の明るさ \(g)")
        XCTAssertEqual(g, green(FrameBlend.mix(a, b, weight: 0.5)!, 105, 100))
    }

    func testFaceAlignmentBringsFacesTogether() {
        // 「顔」= 四角。A は x=100〜140、B は x=140〜180(400×200)。ゼロフローでも中間位置(120〜160)で重なる
        let a = scene(w: 400, h: 200, squareX: 100), b = scene(w: 400, h: 200, squareX: 140)
        let fa = CGRect(x: 0.25, y: 0.4, width: 0.1, height: 0.2)
        let fb = CGRect(x: 0.35, y: 0.4, width: 0.1, height: 0.2)
        let flow = FlowField.constant(width: 100, height: 50, dx: 0, dy: 0)
        let on = MorphCutParameters(strength: 1, facePriority: true)
        let r = MorphCut.morphImage(a, b, weight: 0.5, flow: flow, facesA: [fa], facesB: [fb], params: on)!
        XCTAssertGreaterThan(green(r, 140, 100), 200)
        XCTAssertLessThan(green(r, 102, 100), 120)
        XCTAssertLessThan(green(r, 178, 100), 120)
        // 位置合わせなしなら中心は重ならない端でも明るい残像(半分の明るさ)になる
        let off = MorphCut.morphImage(a, b, weight: 0.5, flow: flow, facesA: [fa], facesB: [fb], params: none)!
        XCTAssertLessThan(green(off, 105, 100), 200)
    }

    func testStrengthZeroEqualsDissolve() {
        let a = scene(w: 400, h: 200, squareX: 100), b = scene(w: 400, h: 200, squareX: 140)
        let flow = FlowField.constant(width: 100, height: 50, dx: 10, dy: 0)
        let p = MorphCutParameters(strength: 0, facePriority: false)
        let r = MorphCut.morphImage(a, b, weight: 0.5, flow: flow, facesA: [], facesB: [], params: p)!
        let d = FrameBlend.mix(a, b, weight: 0.5)!
        for (x, y) in [(10, 10), (105, 100), (125, 100), (165, 100), (300, 50)] { XCTAssertEqual(green(r, x, y), green(d, x, y)) }
    }
}
