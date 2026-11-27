import XCTest
@testable import MovieCutCore

final class ColorManagementTests: XCTestCase {
    typealias CM = ColorManagement

    // MARK: 公知の基準値

    func testSLog3KnownValues() {
        // Sony 公式: 18% グレー = 420/1023、黒(0%)= 95/1023、90% 白 = 598/1023
        XCTAssertEqual(CM.sLog3ToLinear(420.0 / 1023.0), 0.18, accuracy: 1e-6)
        XCTAssertEqual(CM.sLog3ToLinear(95.0 / 1023.0), 0.0, accuracy: 1e-6)
        XCTAssertEqual(CM.sLog3ToLinear(598.0 / 1023.0), 0.90, accuracy: 0.005)
        XCTAssertEqual(CM.linearToSLog3(0.18), 420.0 / 1023.0, accuracy: 1e-6)
        XCTAssertEqual(CM.linearToSLog3(0.90), 598.0 / 1023.0, accuracy: 0.001)
    }

    func testVLogKnownValues() {
        // Panasonic 公式: 黒 = 0.125、18% グレー ≈ 0.4233
        XCTAssertEqual(CM.vLogToLinear(0.125), 0.0, accuracy: 1e-9)
        XCTAssertEqual(CM.linearToVLog(0.18), 0.42331, accuracy: 1e-4)
        XCTAssertEqual(CM.vLogToLinear(0.42331), 0.18, accuracy: 1e-3)
        XCTAssertEqual(CM.linearToVLog(0.0), 0.125, accuracy: 1e-9)
        // 継ぎ目(0.181)で連続
        XCTAssertEqual(CM.vLogToLinear(0.181 - 1e-9), CM.vLogToLinear(0.181 + 1e-9), accuracy: 1e-6)
        XCTAssertEqual(CM.vLogToLinear(0.181), 0.01, accuracy: 1e-4)
    }

    func testCurveRoundTrips() {
        for i in 0...100 {
            let x = Double(i) / 100
            XCTAssertEqual(CM.linearToSLog3(CM.sLog3ToLinear(x)), x, accuracy: 1e-9)
            XCTAssertEqual(CM.linearToVLog(CM.vLogToLinear(x)), x, accuracy: 1e-9)
            XCTAssertEqual(CM.linearToBT709(CM.bt709ToLinear(x)), x, accuracy: 1e-9)
        }
    }

    func testHLGKnownValues() {
        XCTAssertEqual(CM.hlgToSceneLinear(0), 0, accuracy: 1e-12)
        XCTAssertEqual(CM.hlgToSceneLinear(0.5), 1.0 / 12.0, accuracy: 1e-9)   // 信号 0.5 = シーン線形 1/12
        XCTAssertEqual(CM.hlgToSceneLinear(1.0), 1.0, accuracy: 1e-6)          // 信号 1.0 = ピーク
        XCTAssertEqual(CM.hlgToSDRLinear(0.75), 1.0, accuracy: 1e-9)           // 基準白が SDR 白
    }

    // MARK: 行列

    func testMatrixRowsSumToOneAndMatchPublishedValues() {
        for cs in [InputColorSpace.sLog3, .vLog, .rec2020, .hlg] {
            let m = CM.gamutToRec709Matrix(cs)
            for row in m { XCTAssertEqual(row.reduce(0, +), 1, accuracy: 1e-6, "白色点が保たれる: \(cs)") }
        }
        // 公開されている行列(Sony / Panasonic / ITU-R BT.2087)と許容差内で一致
        let sg3: [[Double]] = [[1.6269474, -0.5401385, -0.0868089], [-0.1785155, 1.4179409, -0.2394254], [-0.0444361, -0.1959200, 1.2403561]]
        let vg: [[Double]] = [[1.806576, -0.695697, -0.110879], [-0.170090, 1.305955, -0.135865], [-0.025206, -0.154468, 1.179674]]
        let r2020: [[Double]] = [[1.660491, -0.587641, -0.072850], [-0.124550, 1.132900, -0.008349], [-0.018151, -0.100579, 1.118730]]
        for (cs, ref) in [(InputColorSpace.sLog3, sg3), (.vLog, vg), (.rec2020, r2020)] {
            let m = CM.gamutToRec709Matrix(cs)
            for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(m[i][j], ref[i][j], accuracy: 2e-3, "\(cs)[\(i)][\(j)]") } }
        }
    }

    func testMatrixIdentityAndRoundTrip() {
        XCTAssertEqual(CM.gamutToRec709Matrix(.rec709), [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        for cs in [InputColorSpace.sLog3, .vLog, .rec2020] {
            let m = CM.gamutToRec709Matrix(cs)
            let back = CM.mul(CM.inverse(m), m)
            for i in 0..<3 { for j in 0..<3 { XCTAssertEqual(back[i][j], i == j ? 1 : 0, accuracy: 1e-9) } }
            let v: CM.RGB = (0.2, 0.5, 0.8)
            let r = CM.apply(CM.inverse(m), CM.apply(m, v))
            XCTAssertEqual(r.r, 0.2, accuracy: 1e-9); XCTAssertEqual(r.g, 0.5, accuracy: 1e-9); XCTAssertEqual(r.b, 0.8, accuracy: 1e-9)
        }
    }

    // MARK: 変換本体

    func testRec709IsIdentity() {
        let v: CM.RGB = (0.12, 0.34, 0.56)
        let o = CM.convertToRec709(v, from: .rec709)
        XCTAssertEqual(o.r, v.r); XCTAssertEqual(o.g, v.g); XCTAssertEqual(o.b, v.b)
    }

    func testGreyStaysGreyAndMidGreyMaps() {
        // グレーは色域が違ってもグレーのまま(R=G=B)
        for cs in [InputColorSpace.sLog3, .vLog, .hlg, .rec2020] {
            let o = CM.convertToRec709((0.5, 0.5, 0.5), from: cs)
            XCTAssertEqual(o.r, o.g, accuracy: 1e-9); XCTAssertEqual(o.g, o.b, accuracy: 1e-9)
        }
        // S-Log3 の 18% グレー → 線形 0.18 → BT.709 符号化 ≈ 0.4093
        let o = CM.convertToRec709((420.0 / 1023.0, 420.0 / 1023.0, 420.0 / 1023.0), from: .sLog3)
        XCTAssertEqual(o.r, CM.linearToBT709(0.18), accuracy: 1e-6)
        // Rec.2020 ガンマのグレーは Rec.709 でも同じ値(伝達関数が同じ)
        let g = CM.convertToRec709((0.4, 0.4, 0.4), from: .rec2020)
        XCTAssertEqual(g.r, 0.4, accuracy: 1e-9)
    }

    func testOutputIsClampedAndFinite() {
        for cs in InputColorSpace.allCases {
            for v in [0.0, 1.0] {
                let o = CM.convertToRec709((v, 1 - v, v), from: cs)
                for c in [o.r, o.g, o.b] { XCTAssertTrue(c.isFinite && c >= 0 && c <= 1) }
            }
        }
    }

    func testCubeData() {
        let n = CM.lutSize
        XCTAssertEqual(CM.cubeData(for: .sLog3).count, n * n * n * 4 * MemoryLayout<Float>.size)
        // 角(黒)の値が変換結果と一致
        let d = CM.cubeData(for: .vLog)
        let f = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let black = CM.convertToRec709((0, 0, 0), from: .vLog)
        XCTAssertEqual(Double(f[0]), black.r, accuracy: 1e-6)
        XCTAssertEqual(f[3], 1)
    }

    // MARK: 保存・復元と後方互換

    func testClipRoundTrip() throws {
        for cs in InputColorSpace.allCases where cs != .rec709 {
            var c = Clip(); c.type = .video; c.inputColorSpace = cs
            var p = Project(); p.tracks = [{ var t = Track(name: "v"); t.clips = [c]; return t }()]
            let back = try Project.decode(from: p.encoded())
            XCTAssertEqual(back.tracks[0].clips[0].inputColorSpace, cs)
            XCTAssertEqual(back, p)
        }
    }

    func testRec709IsNotWritten() throws {
        var c = Clip(); c.type = .video; c.inputColorSpace = .rec709
        var p = Project(); p.tracks = [{ var t = Track(name: "v"); t.clips = [c]; return t }()]
        let json = String(decoding: try p.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("inputColorSpace"))
    }

    func testOldFormatWithoutFieldLoadsAsRec709() throws {
        let json = #"{"tracks":[{"clips":[{"type":"video","start":1,"duration":2}]}]}"#
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertNil(p.tracks[0].clips[0].inputColorSpace)
        let again = try Project.decode(from: p.encoded())
        XCTAssertEqual(again, p)
        XCTAssertFalse(String(decoding: try p.encoded(), as: UTF8.self).contains("inputColorSpace"))
    }

    func testUnknownValueIsPreserved() throws {
        let json = #"{"tracks":[{"clips":[{"type":"video","inputColorSpace":"acescct"}]}]}"#
        let p = try Project.decode(from: Data(json.utf8))
        XCTAssertNil(p.tracks[0].clips[0].inputColorSpace)
        XCTAssertTrue(String(decoding: try p.encoded(), as: UTF8.self).contains("acescct"))
    }

    // MARK: 描画

    func testRenderChangesOnlyForNonRec709() throws {
        func frame(_ cs: InputColorSpace?) throws -> [UInt8] {
            var c = Clip(); c.type = .image; c.start = 0; c.duration = 1; c.inputColorSpace = cs
            c.effects = [Effect(.brightness)]   // エフェクトの道へ入れる(未設定の値は何もしない)
            var p = Project(); p.width = 64; p.height = 36
            p.tracks = [{ var t = Track(name: "t"); t.clips = [c]; return t }()]
            let img = try XCTUnwrap(Renderer(project: p, assets: RenderAssets()).renderImage(t: 0.5))
            return Array(try XCTUnwrap(img.dataProvider?.data as Data?))
        }
        XCTAssertEqual(try frame(nil), try frame(.rec709))
    }

    func testApplyIsNoOpForRec709() {
        let img = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertTrue(CM.apply(img, from: .rec709) === img)
    }
}
