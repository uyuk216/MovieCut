import SwiftUI
import MovieCutCore

/// クリップ ▸ 立ち絵を追加…: 立ち絵素材を選んで、再生位置に立ち絵クリップを置く。フォルダ・PSD の取り込みもここから。
struct TachieAddSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var chosen: String?
    @State private var followsEnd = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("立ち絵を追加").font(.headline)
            if model.project.tachies.isEmpty {
                Text("立ち絵素材がありません。パーツのフォルダか PSD を取り込んでください。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("置く立ち絵素材を選びます。クリップは再生位置（\(timecode(model.currentTime))）に、トラックターゲットか空いているレイヤーへ置かれます。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                List(selection: $chosen) {
                    ForEach(model.project.tachies) { t in
                        Text(t.name.isEmpty ? "立ち絵" : t.name).tag(Optional(t.id))
                    }
                }
                .frame(width: 340, height: 140)
            }
            Toggle("プロジェクトの長さに合わせる", isOn: $followsEnd)
                .controlSize(.small)
                .help("再生位置からプロジェクトの終わりまで置き、あとから声を足しても終わりに合わせ続けます（長さを手で変えるとやめます）")
            HStack {
                Button("フォルダから取り込む…") { model.chooseAndImportRigFolder() }
                Button("PSDから取り込む…") { model.chooseAndImportRigPSD() }
            }
            .controlSize(.small)
            HStack {
                Spacer()
                Button("キャンセル") { model.showTachieSheet = false }.keyboardShortcut(.cancelAction)
                Button("追加") {
                    if let id = chosen { model.placeTachie(id, followsEnd: followsEnd) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil || model.isLocked)
            }
        }
        .padding(16)
        .onAppear { chosen = model.selectedTachieId ?? model.tachie(model.selectedClip?.tachieId)?.id ?? model.project.tachies.first?.id }
        .onChange(of: model.project.tachies.count) { _, _ in chosen = model.project.tachies.last?.id }   // 取り込んだら、それを選ぶ
    }
}

/// 左のパネルの「立ち絵素材」一覧(追加・名前の変更・削除)。
struct TachieListSection: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("立ち絵素材").font(.headline)
                Spacer()
                Menu {
                    Button("フォルダから取り込む…") { model.chooseAndImportRigFolder() }
                    Button("PSDから取り込む…") { model.chooseAndImportRigPSD() }
                } label: { Text("＋") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(model.isLocked)
                    .help("立ち絵素材を追加（パーツのフォルダ・PSD）")
            }
            if model.project.tachies.isEmpty {
                Text("パーツのフォルダか PSD を取り込むと、ここに並びます。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.project.tachies) { t in
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.rectangle").foregroundStyle(.secondary)
                    Text(t.name.isEmpty ? "立ち絵" : t.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { _ = model.addTachieClip(tachieId: t.id) } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                        .buttonStyle(.plain).disabled(model.isLocked).help("再生位置に立ち絵クリップを置く")
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(model.selectedTachieId == t.id ? Color(red: 0.96, green: 0.78, blue: 0.24) : Color(nsColor: .separatorColor), lineWidth: model.selectedTachieId == t.id ? 1.5 : 1))
                .contentShape(Rectangle())
                .onTapGesture { model.selectTachie(t.id) }
                .contextMenu {
                    Button("再生位置にクリップを置く") { _ = model.addTachieClip(tachieId: t.id) }
                    Button("削除", role: .destructive) { model.removeTachie(id: t.id) }
                }
            }
        }
    }
}

/// 立ち絵パーツのフォルダに、大きさの違う画像のグループが複数あるときの取り込みシート。グループごとに別の立ち絵素材になる。
struct RigGroupSheet: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("立ち絵パーツの取り込み").font(.headline)
            if let plan = model.rigGroupPlan {
                Text("「\(plan.folderName)」には、画像の大きさが違うグループが \(plan.groups.count) つあります。グループごとに別の立ち絵素材として取り込みます。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(plan.groups.enumerated()), id: \.offset) { i, g in
                    Toggle(isOn: Binding(get: { model.rigGroupPlan?.selected.contains(i) ?? false }, set: { on in
                        if on { model.rigGroupPlan?.selected.insert(i) } else { model.rigGroupPlan?.selected.remove(i) }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.name).font(.system(size: 13, weight: .semibold))
                            Text("\(g.width)×\(g.height) ・ 画像 \(g.imageCount) 枚 ・ " + g.report.rig.slots.map { "\($0.name) \($0.parts.count)" }.joined(separator: "・"))
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { model.rigGroupPlan = nil }.keyboardShortcut(.cancelAction)
                Button("取り込む") { if let plan = model.rigGroupPlan { _ = model.importRigGroups(plan.chosen) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.isLocked || (model.rigGroupPlan?.selected.isEmpty ?? true))
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
