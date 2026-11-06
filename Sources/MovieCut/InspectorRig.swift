import SwiftUI
import AppKit
import ImageIO
import MovieCutCore

/// パーツの小さな見本。大きなキャンバス全面の PNG は、描かれている部分(透明でない範囲)に切り詰めて見せる。
struct RigPartThumb: View {
    let path: String?
    let selected: Bool
    var label: String = ""
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(2)
            } else {
                Text(path == nil ? "なし" : "…").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if !label.isEmpty {
                VStack { Spacer(); Text(label).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 3).background(.black.opacity(0.55)).foregroundStyle(.white).cornerRadius(3) }.padding(2)
            }
        }
        .frame(width: 56, height: 56)
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2.5 : 1))
        .task(id: path) {
            guard let path else { image = nil; return }
            image = await Task.detached(priority: .utility) { RigThumbCache.thumbnail(path) }.value
        }
    }
}

enum RigThumbCache {
    private static let cache = NSCache<NSString, NSImage>()

    /// 読み込み済みなら返す(描画中に重い読み込みをしない)。
    static func cachedThumbnail(_ path: String) -> NSImage? { cache.object(forKey: path as NSString) }

    private static let pending = NSMutableSet()

    /// 背景で読んでキャッシュに入れ、終わったら主スレッドで `done` を呼ぶ(同じパスの二重読みはしない)。
    static func prefetch(_ path: String, done: @escaping @MainActor () -> Void) {
        let key = path as NSString
        guard cache.object(forKey: key) == nil else { return }
        objc_sync_enter(pending); let fresh = !pending.contains(key); if fresh { pending.add(key) }; objc_sync_exit(pending)
        guard fresh else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = thumbnail(path)
            objc_sync_enter(pending); pending.remove(key); objc_sync_exit(pending)
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    /// 長辺 384 で読み、透明でない範囲に切り詰めた見本。
    static func thumbnail(_ path: String) -> NSImage? {
        if let c = cache.object(forKey: path as NSString) { return c }
        guard let cg = RigImageLoader.thumbnail(path, maxPixel: 384) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        var out = cg
        if ok {
            var minX = w, maxX = -1, minY = h, maxY = -1
            for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 16 {
                if x < minX { minX = x }; if x > maxX { maxX = x }; if y < minY { minY = y }; if y > maxY { maxY = y }
            } }
            if maxX >= minX, maxY >= minY, let c = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) { out = c }
        }
        let img = NSImage(cgImage: out, size: NSSize(width: out.width / 2, height: out.height / 2))
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}

/// 立ち絵パーツの欄(スロットごとの見本の一覧・まばたき・口・表情)。
struct RigInspectorSection: View {
    @ObservedObject var model: ProjectModel
    let tachieId: String
    let rig: CharacterRig

    private func fileName(_ p: String?) -> String { p.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "なし" }

    var body: some View {
        InspectorSection(title: "立ち絵パーツ")
        Text("見本を押すと、そのパーツに切り替わります。目と口は、まばたき・口パク・表情で自動で切り替わります")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        ForEach(rig.slots, id: \.name) { slot in slotView(slot) }
        expressionsView()
    }

    @ViewBuilder private func slotView(_ slot: RigSlot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(slot.name)（\(slot.parts.count)）").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(slot.active >= 0 ? "\(slot.active + 1) 番" : "出さない").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 4) {
                    Button { model.rigSelect(tachieId: tachieId, slot: slot.name, index: -1) } label: {
                        RigPartThumb(path: nil, selected: slot.active == -1)
                    }.buttonStyle(.plain).help("\(slot.name)を出さない")
                    ForEach(Array(slot.parts.enumerated()), id: \.offset) { i, p in
                        Button { model.rigSelect(tachieId: tachieId, slot: slot.name, index: i) } label: {
                            RigPartThumb(path: p, selected: slot.active == i, label: badge(slot.name, i))
                        }.buttonStyle(.plain).help("\(i + 1) 番: \(fileName(p))")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 66)
            offsetRow(slot)
            if slot.name == CharacterRig.eyeSlot { blinkRow() }
            if slot.name == CharacterRig.mouthSlot { mouthRows() }
        }
        .disabled(model.isLocked)
    }

    /// 今選んでいるパーツの位置の補正(基準キャンバスの画素。x が右、y が下)。数値で直接入れるか、◀▶ で 1 ずつ動かす。
    @ViewBuilder private func offsetRow(_ slot: RigSlot) -> some View {
        if slot.active >= 0, slot.active < slot.parts.count {
            let path = slot.parts[slot.active]
            let off = rig.partOffsets?[path] ?? PartOffset()
            HStack(spacing: 6) {
                Text("位置の補正").font(.system(size: 11)).foregroundStyle(.secondary)
                offsetField("x", value: off.dx) { model.setTachiePartOffset(tachieId: tachieId, path: path, offset: PartOffset(dx: $0, dy: off.dy)) }
                offsetField("y", value: off.dy) { model.setTachiePartOffset(tachieId: tachieId, path: path, offset: PartOffset(dx: off.dx, dy: $0)) }
                Button { model.setTachiePartOffset(tachieId: tachieId, path: path, offset: PartOffset()) } label: { Image(systemName: "arrow.counterclockwise") }
                    .disabled(off.isZero).help("このパーツの位置の補正を 0 に戻す")
            }
            .controlSize(.small)
        }
    }

    private func offsetField(_ label: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            NumField(value: value, step: 1, decimals: 0, clamp: { max(-4000, min(4000, $0.rounded())) }, onCommit: set, onStep: set)
        }
    }

    /// 見本に出す印(まばたき・口の割り当て)。
    private func badge(_ slot: String, _ i: Int) -> String {
        var tags: [String] = []
        if slot == CharacterRig.eyeSlot, rig.blink == i { tags.append("瞬") }
        if slot == CharacterRig.mouthSlot {
            if rig.mouthClosed == i { tags.append("閉") }
            if rig.mouthOpen == i { tags.append("開") }
            for (k, l) in [("a", "あ"), ("i", "い"), ("u", "う"), ("e", "え"), ("o", "お")] where rig.vowels?[k] == i { tags.append(l) }
        }
        return tags.joined()
    }

    private func blinkRow() -> some View {
        HStack(spacing: 6) {
            Button("これを まばたき") { model.rigAssignBlink(tachieId: tachieId) }
                .help("今選んでいる目を「閉じた目」にして、ときどき一瞬だけ出します")
                .disabled(rig.slot(CharacterRig.eyeSlot)?.active ?? -1 < 0)
            Button { model.rigClearBlink(tachieId: tachieId) } label: { Image(systemName: "xmark") }
                .disabled(rig.blink == nil).help("まばたきを外す")
            Text(rig.blink.map { "まばたき: \($0 + 1) 番" } ?? "まばたきなし").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private func mouthRows() -> some View {
        let roles: [(String, String)] = [("closed", "閉じ"), ("open", "開き"), ("a", "あ"), ("i", "い"), ("u", "う"), ("e", "え"), ("o", "お")]
        func assigned(_ r: String) -> Int? {
            switch r { case "closed": return rig.mouthClosed; case "open": return rig.mouthOpen; default: return rig.vowels?[r] }
        }
        let cur = rig.slot(CharacterRig.mouthSlot)?.active ?? -1
        return VStack(alignment: .leading, spacing: 4) {
            Text("今の口を割り当てる（話していない間は「閉じ」、話している間は「開き」か あいうえお）").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(roles, id: \.0) { r, label in
                    Button(label) { model.rigAssignMouth(tachieId: tachieId, role: r) }
                        .help("口: \(label) に今の口を割り当てる" + (assigned(r).map { "（今は \($0 + 1) 番）" } ?? ""))
                        .disabled(cur < 0)
                        .overlay(alignment: .topTrailing) { if assigned(r) != nil { Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: -2) } }
                }
                Button { for (r, _) in roles { model.rigAssignMouth(tachieId: tachieId, role: r, use: false) } } label: { Image(systemName: "xmark") }
                    .help("口の割り当てをすべて外す")
                    .disabled(roles.allSatisfy { assigned($0.0) == nil })
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private func expressionsView() -> some View {
        let items = (rig.expressions ?? [:]).sorted { $0.key < $1.key }
        InspectorSection(title: "表情（パーツの組み合わせ）")
        Text("セリフの先頭に [名前] と書くと、その行の間この組み合わせになります（口は話し方に合わせて動きます）")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        ForEach(items, id: \.key) { key, picks in
            HStack(spacing: 6) {
                NameField(value: key) { model.rigRenameExpression(tachieId: tachieId, from: key, to: $0) }
                Button("選ぶ") { model.rigApplyExpression(tachieId: tachieId, name: key) }.help("この表情のパーツを今の選択にする")
                Button("更新") { model.rigRecaptureExpression(tachieId: tachieId, name: key) }.help("今の選択でこの表情を上書きする")
                Button { model.rigDeleteExpression(tachieId: tachieId, name: key) } label: { Image(systemName: "minus.circle") }.help("この表情を消す")
            }
            .controlSize(.small)
            .disabled(model.isLocked)
        }
        Button { _ = model.rigAddExpression(tachieId: tachieId) } label: {
            Label("今の選択を表情に追加", systemImage: "plus.circle").frame(maxWidth: .infinity)
        }
        .controlSize(.small)
        .disabled(model.isLocked)
        .help("眉・目・口などの今の選択を、名前をつけた表情として覚えます")
    }
}
