import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MovieCutCore

/// 髪パーツ(体より縦に長い)の位置と重なり順: 揃え方(上・中央・下)・体の後ろのスロット・実データでの判定。
final class RigHairAlignmentTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rig-align-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func png(_ name: String, w: Int, h: Int, color: (UInt8, UInt8, UInt8), box: CGRect? = nil) throws -> String {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1))
        ctx.fill(box ?? CGRect(x: 0, y: 0, width: w, height: h))
        let url = tmp.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    func rgb(_ img: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var d = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = CGContext(data: &d, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let i = (y * img.width + x) * 4
        return [Int(d[i]), Int(d[i + 1]), Int(d[i + 2]), Int(d[i + 3])]
    }

    /// 40×40 の黒い体と、40×60 の画像(上端 10px だけ白 = 髪の先端)。
    func compose(_ a: PartAlignment?) throws -> CGImage {
        let base = try png("base.png", w: 40, h: 40, color: (0, 0, 0))
        // CGContext の画像は下が原点: box y=50..60 が「上端 10px」
        let tall = try png("tall.png", w: 40, h: 60, color: (255, 255, 255), box: CGRect(x: 0, y: 50, width: 40, height: 10))
        return try XCTUnwrap(RigFrameCache().frame(paths: [base, tall], height: 40, alignment: a ?? .bottom))
    }

    func testAlignmentTopCenterBottomPlacement() throws {
        // 40×40 の黒い体に、40×60 の髪(画像の上端 10px と下端 10px だけ白)。キャンバスのどこに白が出るか。
        let base = try png("pb.png", w: 40, h: 40, color: (0, 0, 0))
        let upper = try png("pu.png", w: 40, h: 60, color: (255, 255, 255), box: CGRect(x: 0, y: 50, width: 40, height: 10))   // 画像の上端 10px
        let lower = try png("pl.png", w: 40, h: 60, color: (255, 255, 255), box: CGRect(x: 0, y: 0, width: 40, height: 10))     // 画像の下端 10px
        func img(_ part: String, _ a: PartAlignment) throws -> CGImage { try XCTUnwrap(RigFrameCache().frame(paths: [base, part], height: 40, alignment: a)) }
        let white = [255, 255, 255, 255], black = [0, 0, 0, 255]
        // 下揃え(従来): 髪の下端がキャンバスの下端。上端 10px は 20px 上にはみ出して見えない
        XCTAssertEqual(rgb(try img(lower, .bottom), 20, 39), white); XCTAssertEqual(rgb(try img(upper, .bottom), 20, 0), black)
        // 上揃え: 髪の上端がキャンバスの上端。上端 10px が y 0..9 に出る。下端は見えない
        XCTAssertEqual(rgb(try img(upper, .top), 20, 5), white); XCTAssertEqual(rgb(try img(upper, .top), 20, 15), black)
        XCTAssertEqual(rgb(try img(lower, .top), 20, 39), black)
        // 中央揃え: 上下に 10px ずつはみ出す。どちらの端の白も見えず、中の位置が 10px 分だけ上下にずれる
        XCTAssertEqual(rgb(try img(upper, .center), 20, 0), black); XCTAssertEqual(rgb(try img(lower, .center), 20, 39), black)
        // 目印: 髪の y=10..20(画像の上端から 10〜20px)が白。上揃えでは 10..19、中央では 0..9、下揃えでは見えない
        let mid = try png("pm.png", w: 40, h: 60, color: (255, 255, 255), box: CGRect(x: 0, y: 40, width: 40, height: 10))
        XCTAssertEqual(rgb(try img(mid, .top), 20, 15), white); XCTAssertEqual(rgb(try img(mid, .top), 20, 5), black)
        XCTAssertEqual(rgb(try img(mid, .center), 20, 5), white); XCTAssertEqual(rgb(try img(mid, .center), 20, 15), black)
        XCTAssertEqual(rgb(try img(mid, .bottom), 20, 5), black)
    }

    func testAlignmentIsPartOfCacheKey() throws {
        let base = try png("cb.png", w: 40, h: 40, color: (0, 0, 0))
        let tall = try png("ct.png", w: 40, h: 60, color: (255, 255, 255), box: CGRect(x: 0, y: 0, width: 40, height: 10))
        let c = RigFrameCache()
        _ = c.frame(paths: [base, tall], height: 40)
        _ = c.frame(paths: [base, tall], height: 40, alignment: .center)
        XCTAssertEqual(c.composeCount, 2)
        _ = c.frame(paths: [base, tall], height: 40, alignment: .center)
        XCTAssertEqual(c.composeCount, 2)
    }

    func testAlignmentAndBehindAreOptionalAndRoundTrip() throws {
        var rig = CharacterRig(slots: [RigSlot(name: "体", parts: ["b"]), RigSlot(name: "髪", parts: ["h"])])
        let plain = try JSONEncoder().encode(rig)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("alignment"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("behindBody"))
        rig = RigEditing.setAlignment(rig, .center)
        rig = RigEditing.setSlotBehind(rig, slot: "髪", behind: true)
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let data = try enc.encode(rig)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"alignment\":\"center\"")); XCTAssertTrue(text.contains("\"behindBody\":true"))
        let back = try JSONDecoder().decode(CharacterRig.self, from: data)
        XCTAssertEqual(back, rig)
        XCTAssertEqual(try enc.encode(back), data)
        // 下揃え・false は「未設定」に戻る(書かない)
        let reset = RigEditing.setSlotBehind(RigEditing.setAlignment(rig, .bottom), slot: "髪", behind: false)
        XCTAssertNil(reset.alignment); XCTAssertNil(reset.slots[1].behindBody)
        XCTAssertEqual(try enc.encode(reset), try enc.encode(CharacterRig(slots: rig.slots.map { var s = $0; s.behindBody = nil; return s })))
        // 同じ値の編集は同じ値
        XCTAssertEqual(RigEditing.setAlignment(rig, .center), rig)
        XCTAssertEqual(RigEditing.setSlotBehind(rig, slot: "髪", behind: true), rig)
        XCTAssertEqual(RigEditing.setSlotBehind(rig, slot: "なし", behind: true), rig)
        // 読めない値は捨てずに書き戻す
        let odd = try JSONDecoder().decode(CharacterRig.self, from: Data(#"{"slots":[{"name":"体","parts":[],"active":0,"behindBody":"x"}],"alignment":"diagonal"}"#.utf8))
        XCTAssertNil(odd.alignment); XCTAssertNil(odd.slots[0].behindBody)
        let again = String(decoding: try enc.encode(odd), as: UTF8.self)
        XCTAssertTrue(again.contains("diagonal")); XCTAssertTrue(again.contains("\"behindBody\":\"x\""))
    }

    func testBehindSlotsGoFirstInPaths() {
        var rig = CharacterRig(slots: [
            RigSlot(name: "体", parts: ["body"]), RigSlot(name: "髪", parts: ["hairBack", "hairFront"], active: 0), RigSlot(name: "目", parts: ["eye"]),
        ])
        XCTAssertEqual(rig.paths(active: rig.resolvedActive()), ["body", "hairBack", "eye"])
        rig = RigEditing.setSlotBehind(rig, slot: "髪", behind: true)
        XCTAssertEqual(rig.paths(active: rig.resolvedActive()), ["hairBack", "body", "eye"])
        XCTAssertEqual(rig.offsets(for: rig.paths(active: rig.resolvedActive())).count, 3)
    }

    func testBehindSlotIsDrawnUnderTheBodyPixelwise() throws {
        let body = try png("bb.png", w: 20, h: 20, color: (255, 0, 0))
        let hair = try png("hb.png", w: 20, h: 20, color: (0, 255, 0))
        var rig = CharacterRig(slots: [RigSlot(name: "体", parts: [body]), RigSlot(name: "髪", parts: [hair], active: 0)])
        func top(_ r: CharacterRig) -> [Int] { rgb(RigFrameCache().frame(paths: r.paths(active: r.resolvedActive()), height: 20)!, 10, 10) }
        XCTAssertEqual(top(rig), [0, 255, 0, 255])
        rig = RigEditing.setSlotBehind(rig, slot: "髪", behind: true)
        XCTAssertEqual(top(rig), [255, 0, 0, 255])
    }

    func testImporterUsesCenterWhenSizesDifferAndBehindForBackHair() {
        let sizes: [String: (w: Int, h: Int)] = ["体 (1).png": (30, 30), "眉 (1).png": (30, 30), "目 (1).png": (30, 30), "口 (1).png": (30, 30),
                                                 "後ろ髪 (1).png": (30, 32), "後ろ髪 (2).png": (30, 32)]
        let files = sizes.keys.map { (path: "/x/\($0)", parent: "x") }
        let rep = RigFolderImporter.group(files: files, sizeOf: { sizes[($0 as NSString).lastPathComponent] })
        XCTAssertEqual(rep?.rig.alignment, .center)
        XCTAssertEqual(rep?.rig.slot("髪")?.behindBody, true)
        // 全部同じ大きさなら何も足さない
        let same = ["体 (1).png", "眉 (1).png", "目 (1).png", "口 (1).png", "髪 (1).png"].map { (path: "/x/\($0)", parent: "x") }
        let r2 = RigFolderImporter.group(files: same, sizeOf: { _ in (30, 30) })
        XCTAssertNil(r2?.rig.alignment); XCTAssertNil(r2?.rig.slot("髪")?.behindBody)
    }

    func testSuggestedOffsetsFollowAlignment() {
        let rig = CharacterRig(slots: [RigSlot(name: "体", parts: ["b"]), RigSlot(name: "髪", parts: ["h"], active: 0)])
        var c = rig; c.alignment = .center
        let canvas: (String) -> (w: Int, h: Int)? = { $0 == "b" ? (100, 100) : (100, 120) }
        // 髪の不透明部分が上端いっぱい(0...0.1)。下揃えだと y=-20..-8 ではみ出す → 20 下げる。中央なら y=-10..2 → 10 下げる
        let opaque: (String) -> CGRect? = { _ in CGRect(x: 0, y: 0, width: 1, height: 0.1) }
        XCTAssertEqual(RigAlignment.suggestOffsets(for: rig, base: (100, 100), canvas: canvas, opaque: opaque)["h"], PartOffset(dx: 0, dy: 20))
        XCTAssertEqual(RigAlignment.suggestOffsets(for: c, base: (100, 100), canvas: canvas, opaque: opaque)["h"], PartOffset(dx: 0, dy: 10))
    }

    // MARK: 実データ(無ければ飛ばす): 髪 3000×3200 と体 3000×3000

    func testRealHairAlignmentMatchesPSDMarginsIfPresent() throws {
        let dir = "/Users/USER/動画素材/立ち絵/立ち絵素材フォルダ"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir), "素材フォルダがありません")
        let rep = try XCTUnwrap(RigFolderImporter.scan(folder: URL(fileURLWithPath: dir)))
        XCTAssertEqual(rep.rig.alignment, .center, "髪(3200)が体(3000)より長いので、取り込みは中央揃えにする")
        XCTAssertNil(rep.rig.slot("髪")?.behindBody, "髪(1)〜(5)は前髪・側面の房なので体の前")
        // 体の不透明部分の上下の余白(3000 の画像上)。中央揃えで髪キャンバス(3200)に置くと、PSD(体の余白が上 226 / 下 208)と同じようにほぼ対称になる
        let body = try XCTUnwrap(RigHeuristics.opaqueFraction(dir + "/霊夢正面ver1 (1).png", maxPixel: 750))
        let top = body.minY * 3000, bottom = (1 - body.maxY) * 3000
        func asym(_ shift: Double) -> Double { abs((top + shift) - (bottom + 200 - shift)) }
        print("体の余白 上 \(Int(top)) / 下 \(Int(bottom)); 非対称(上揃え/中央/下揃え) = \(Int(asym(0))) / \(Int(asym(100))) / \(Int(asym(200)))")
        XCTAssertLessThan(asym(100), asym(0)); XCTAssertLessThan(asym(100), asym(200))
        if let psd = try? PSDParser.parse(Data(contentsOf: URL(fileURLWithPath: "/Users/USER/Downloads/立ち絵素材.psd"), options: .mappedIfSafe)),
           let l = psd.layers.first(where: { $0.group == .none && $0.effectivelyVisible && $0.height > 2000 }) {
            let pTop = Double(l.top), pBottom = Double(psd.height - l.bottom)
            print("PSD の体の余白 上 \(Int(pTop)) / 下 \(Int(pBottom)) (キャンバス \(psd.height))")
            XCTAssertLessThan(abs(pTop - pBottom), 60, "PSD の体はキャンバスの上下の中央に置かれている")
        }
        // 合成の高さは体(基準)のまま、髪を足しても落ちない
        var r = rep.rig
        r = RigEditing.select(r, slot: "髪", index: 1)
        let img = try XCTUnwrap(RigFrameCache().frame(paths: r.paths(active: r.resolvedActive()), height: 300, offsets: r.offsets(for: r.paths(active: r.resolvedActive())), alignment: r.alignmentOrDefault))
        XCTAssertEqual(img.height, 300)
    }
}
