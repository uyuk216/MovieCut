import SwiftUI
import UniformTypeIdentifiers
import MovieCutCore

extension UTType {
    /// 新しい形式 `.mcpjc`(JSON)。Info.plist の UTExportedTypeDeclarations と同じ識別子。保存は必ずこれ。
    static let mcpjc = UTType(exportedAs: "jp.local.moviecut.project", conformingTo: .json)
    /// 旧形式 `.ymproj`(中身は同じ JSON)。読み込み専用の互換。Info.plist の UTImportedTypeDeclarations と同じ識別子。
    /// 新しい型に適合させてある(= 旧ファイルも「Movie Cut のプロジェクト」として開ける)。
    static let ymproj = UTType(importedAs: "jp.local.yukkuri-editor.project", conformingTo: .mcpjc)
}

/// `.mcpjc` のドキュメント(旧 `.ymproj` も開ける)。開く/保存/別名/最近/未保存マークは DocumentGroup(NSDocument)が受け持つ。
/// 中身は ProjectModel が持つ(1 ドキュメントに 1 つ)。
/// 旧形式を開いた書類は「読み込み専用の型」。SwiftUI は「保存」で元の `.ymproj` へ同じ形式のまま書き戻す(拡張子は変えない)。
/// 「別名で保存…」が提案する拡張子は `.mcpjc`。新規書類の保存は常に `.mcpjc`。
final class ProjectDocument: ReferenceFileDocument {
    typealias Snapshot = Data

    static var readableContentTypes: [UTType] { [.mcpjc, .ymproj] }
    static var writableContentTypes: [UTType] { [.mcpjc] }

    let model: ProjectModel

    init() {
        // 復元で渡された書類があれば、新しい書類はその中身で始める(RecoveryInbox)
        let restored = onMain { RecoveryInbox.take() }
        // ファイル ▸ テンプレートから新規作成 で渡された中身(無題の書類として始める)
        let fromTemplate = onMain { TemplateInbox.take() }
        model = onMain { ProjectModel(project: restored ?? fromTemplate ?? .new()) }
        onMain { model.startAutosave(restored: restored != nil) }
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // 旧形式(キャラクターが立ち絵を持つ)は、立ち絵素材 + 立ち絵クリップへ移して開く(保存すると新形式)
        let p = try Project.decodeMigrating(from: data)
        model = onMain { ProjectModel(project: p) }
        onMain { model.startAutosave() }
    }

    func snapshot(contentType: UTType) throws -> Data {
        // 主スレッド以外から呼ばれる(保存中は主スレッドが待っている)ので、写しから作る
        try model.mirror.get().encoded()
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        // 保存したら最近使った項目へ(保存先が決まっているときだけ。書き込みが済んだあとに記録する)
        // あわせて、保存した中身を世代バックアップへ残す(保存先が決まっているときだけ。別のキューで書き、保存を待たせない)
        DispatchQueue.main.async { [model] in
            MainActor.assumeIsolated {
                RecentProjectsController.shared.record(url: model.fileURL)
                ProjectVersionRecorder.record(data: snapshot, projectURL: model.fileURL)
            }
        }
        return FileWrapper(regularFileWithContents: snapshot)
    }
}

/// どのスレッドから呼ばれても主スレッドで実行する(ファイルの読み込みは主スレッド以外で呼ばれる)。
func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
    return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
}
