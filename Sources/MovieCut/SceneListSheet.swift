import SwiftUI
import MovieCutCore

/// クリップ ▸ シーン一覧…(W3-01): プロジェクトのシーン(名前付きの独立タイムライン)を一覧し、
/// 作成・名前変更・複製・削除・配置・開くを行う。計算とポリシー(参照中は削除不可・循環防止)は
/// MovieCutCore の `SceneEditing`、Undo と状態は `ProjectModel+Scenes` が持つ。
struct SceneListSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var newName = ""
    @State private var renamingId: String?
    @State private var renameText = ""

    private var scenes: [MovieCutCore.SceneDefinition] { model.rootProject.scenes }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("シーン一覧").font(.title3.bold())
                Spacer()
                Text("\(scenes.count) 件").foregroundStyle(.secondary).monospacedDigit()
            }
            if scenes.isEmpty {
                Text("シーンがありません。下の欄から作成できます。シーンは名前付きの独立タイムラインで、タイムラインへ何箇所でも配置して再利用できます。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(scenes) { scene in
                        row(scene)
                    }
                }
                .frame(minHeight: 220)
            }
            HStack {
                TextField("新しいシーンの名前", text: $newName)
                    .frame(width: 220)
                    .onSubmit { create() }
                Button("シーンを作成") { create() }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("閉じる") { model.showSceneListSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            Text("参照されているシーンは削除できません(先にシーンクリップを削除してください)。「開く」でシーンの中身をタイムラインで編集できます。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 640)
    }

    @ViewBuilder
    private func row(_ scene: MovieCutCore.SceneDefinition) -> some View {
        let refs = SceneEditing.referenceCount(in: model.rootProject, sceneId: scene.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if renamingId == scene.id {
                    TextField("シーンの名前", text: $renameText)
                        .frame(width: 200)
                        .onSubmit { commitRename(scene) }
                    Button("決定") { commitRename(scene) }
                    Button("やめる") { renamingId = nil }
                } else {
                    Text(scene.name).bold()
                    Text("尺 \(Self.seconds(SceneEditing.duration(of: scene))) 秒 / 参照 \(refs) 箇所")
                        .foregroundStyle(.secondary).monospacedDigit()
                    if model.editingSceneId == scene.id {
                        Text("編集中").foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("開く") {
                    model.showSceneListSheet = false
                    _ = model.enterScene(scene.id)
                }
                .disabled(model.isInsideScene || model.isInsideCompound)
                Button("配置") { _ = model.placeSceneClip(scene.id) }
                    .disabled(SceneEditing.duration(of: scene) <= 0)
                Button("名前を変更") { renamingId = scene.id; renameText = scene.name }
                Button("複製") { _ = model.duplicateScene(scene.id) }
                Button("削除") { _ = model.deleteScene(scene.id) }
                    .disabled(refs > 0)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if model.createScene(name: name) != nil { newName = "" }
    }

    private func commitRename(_ scene: MovieCutCore.SceneDefinition) {
        if model.renameScene(scene.id, to: renameText) { renamingId = nil }
    }

    private static func seconds(_ v: Double) -> String { String(format: "%.2f", v) }
}
