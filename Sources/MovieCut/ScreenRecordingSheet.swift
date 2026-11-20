import SwiftUI
import AppKit
import MovieCutCore

/// 画面収録シート(ファイル ▸ 画面を収録…)。
/// 許可が無いときは始めずに案内を出す。収録が終わったら、できた .mov を既存の「素材を追加」と
/// 同じ経路(`addMedia`)でプロジェクトへ入れる。
struct ScreenRecordingSheet: View {
    @ObservedObject var model: ProjectModel
    @StateObject private var controller = ScreenRecordingController()
    @State private var addedToProject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("画面を収録")
                .font(.headline)

            if !controller.permissionGranted {
                permissionGuide
            } else {
                settingsForm
            }

            if let error = controller.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error.message)
                        .foregroundStyle(.red)
                    if let guidance = error.guidance {
                        Text(guidance)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if controller.phase == .finished, let url = controller.finishedURL {
                Label(addedToProject ? "収録をプロジェクトに追加しました: \(url.lastPathComponent)" : "収録しました: \(url.lastPathComponent)",
                      systemImage: "checkmark.circle")
                    .font(.callout)
            }

            HStack {
                Spacer()
                if controller.phase == .recording || controller.phase == .stopping {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text(ScreenRecordingFileNaming.elapsedText(controller.elapsed))
                            .monospacedDigit()
                        Button("停止") { Task { await controller.stopRecording() } }
                            .disabled(controller.phase != .recording)
                    }
                } else {
                    Button("閉じる") { close() }
                        .keyboardShortcut(.cancelAction)
                    if controller.permissionGranted {
                        Button(controller.phase == .failed || controller.phase == .finished ? "もう一度" : "収録を開始") {
                            if controller.phase == .failed || controller.phase == .finished {
                                controller.backToIdle()
                            } else {
                                Task { await controller.startRecording() }
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.machine.isActive)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            controller.refreshPermission()
            if controller.permissionGranted { Task { await controller.refreshTargets() } }
        }
        .onChange(of: controller.finishedURL) { _, url in
            guard let url else { return }
            Task { @MainActor in
                _ = await model.addMedia(urls: [url])
                addedToProject = true
            }
        }
        .onDisappear {
            Task { await controller.cancelIfNeeded() }
        }
    }

    // MARK: 許可の案内

    private var permissionGuide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("画面収録の許可が必要です", systemImage: "lock.shield")
                .font(.subheadline).bold()
            Text("Mac の画面を収録するには、システム設定で Movie Cut に「画面収録」の許可が必要です。許可がない間は収録を始めません。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("許可を求める") { controller.requestPermission() }
                Button("システム設定を開く") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("許可の状態を確認") {
                    controller.refreshPermission()
                    if controller.permissionGranted { Task { await controller.refreshTargets() } }
                }
            }
        }
    }

    // MARK: 設定

    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("対象", selection: $controller.kind) {
                ForEach(ScreenCaptureSourceKind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.machine.isActive)

            switch controller.kind {
            case .display, .region:
                HStack {
                    Picker("ディスプレイ", selection: $controller.displayID) {
                        ForEach(controller.targets.displays, id: \.displayID) { d in
                            Text(d.title).tag(d.displayID)
                        }
                    }
                    Button("更新") { Task { await controller.refreshTargets() } }
                }
                .disabled(controller.machine.isActive)
            case .window:
                HStack {
                    Picker("ウィンドウ", selection: $controller.windowID) {
                        ForEach(controller.targets.windows, id: \.windowID) { w in
                            Text(w.title).tag(w.windowID)
                        }
                    }
                    Button("更新") { Task { await controller.refreshTargets() } }
                }
                .disabled(controller.machine.isActive)
            }

            if controller.kind == .region {
                HStack(spacing: 10) {
                    numberField("X", value: $controller.regionX)
                    numberField("Y", value: $controller.regionY)
                    numberField("幅", value: $controller.regionWidth)
                    numberField("高さ", value: $controller.regionHeight)
                }
                .disabled(controller.machine.isActive)
                Text("ディスプレイの左上からの位置と大きさ(ポイント)です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("システムの音を入れる", isOn: $controller.includeSystemAudio)
                .disabled(controller.machine.isActive)
            HStack {
                Picker("フレームレート", selection: $controller.fps) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .fixedSize()
                Spacer()
                Text("保存先: \(controller.outputDirectory.lastPathComponent)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("変更…") { chooseOutputDirectory() }
                    .disabled(controller.machine.isActive)
            }
            .disabled(controller.machine.isActive)
        }
    }

    private func numberField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label)
            TextField(label, value: value, format: .number)
                .frame(width: 64)
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = controller.outputDirectory
        panel.prompt = "選択"
        if FilePanelPresenter.shared.runModal(panel) == .OK, let url = panel.url {
            controller.outputDirectory = url
        }
    }

    private func close() {
        Task { await controller.cancelIfNeeded() }
        model.showScreenRecordingSheet = false
    }
}
