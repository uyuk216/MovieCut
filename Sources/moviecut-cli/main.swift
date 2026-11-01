import Foundation
import MovieCutCore
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())

func optValue(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// --size WxH(アプリのシートと同じ検証と日本語のメッセージ)。
func parseSize(_ s: String) -> (Int, Int) {
    switch ResolutionInput.parseAndValidate(s) {
    case .success(let sz): return (sz.width, sz.height)
    case .failure(let e): fail(e.message)
    }
}

/// --fps 29.97 / 12.5 / 30000/1001(アプリのシートと同じ検証と日本語のメッセージ)。
func parseFps(_ s: String) -> Double {
    switch FrameRateInput.parse(s) {
    case .success(let v): return v
    case .failure(let e): fail("--fps: " + e.message)
    }
}

/// 書き出して、進み具合(約10%ごと)を stderr、最後に コマ数・秒・実時間比 を stdout に出す。
func runExport(_ p: Project, to url: URL, preset: ExportPreset? = nil, spec: ExportSpec? = nil, bitrateMbps: Double? = nil, range: ExportRange? = nil) async throws {
    let chosen = spec ?? preset?.spec
    let audioOnly = chosen?.audioOnly ?? false
    let resolved = chosen?.apply(to: p) ?? p
    let frames = audioOnly ? 0 : Exporter(project: resolved, assets: RenderAssets(), range: range).totalFrames
    if !audioOnly {
        let plan = Exporter(project: resolved, assets: RenderAssets()).plan
        if let b = bitrateMbps ?? chosen?.bitrateMbps { print(String(format: "bitrate: %.1f Mbps(指定)", b)) }
        print("plan: \(plan.width)x\(plan.height) \(plan.codec)\(plan.usesFallbackCodec ? " (H.264 では書けないので HEVC に切り替え)" : "") fps=\(FrameRate.label(resolved.fps)) (\(resolved.frameRate.num)/\(resolved.frameRate.den))")
        if let w = OutputPlan.heavyWarning(width: plan.width, height: plan.height, fps: resolved.fps) { print("caution: " + w) }
    }
    var nextMark = 0.1
    let t0 = Date()
    try await ExportJob.run(project: p, preset: preset, spec: spec, bitrateMbps: bitrateMbps, range: range, to: url) { v in
        if v >= nextMark - 1e-9 {
            FileHandle.standardError.write(Data(String(format: "  %3.0f%%\n", v * 100).utf8))
            nextMark = (v * 10 + 1e-9).rounded(.down) / 10 + 0.1
        }
    }
    let wall = Date().timeIntervalSince(t0)
    let dur = range?.duration ?? p.endTime
    if let r = range { print(String(format: "range: %.3f - %.3f s (%.3f s)", r.start, r.end, r.duration)) }
    print(String(format: "wrote %@ frames=%d wall=%.2fs speed=%.2fx realtime (%.1f fps)", url.path, frames, wall, dur / max(wall, 1e-9), Double(frames) / max(wall, 1e-9)))
}
/// --range a:b(秒。`project` ならプロジェクトに保存してある範囲)。指定が無ければ nil。
func parseRange(_ p: Project) -> ExportRange? {
    guard let s = optValue("--range") else { return nil }
    if s == "project" {
        guard let r = p.exportRange else { fail("--range project: プロジェクトに書き出し範囲が設定されていません") }
        return r
    }
    switch ExportRange.parse(s, endTime: p.endTime) {
    case .success(let r): return r
    case .failure(let e): fail("--range: " + e.message)
    }
}

// MARK: - ファン(書き出し中の最大化)

func fanLine(_ s: FanStatus) -> String {
    func n(_ v: Double?) -> String { v.map { String(Int($0)) } ?? "?" }
    let fans = s.fans.map { f in
        "fan\(f.index) mode=\(f.mode) target=\(n(f.targetRPM)) actual=\(n(f.actualRPM)) (min \(n(f.minimumRPM)) / max \(n(f.maximumRPM)))"
    }.joined(separator: "; ")
    return fans + (s.hottestCoreCelsius.map { String(format: " hottest-core=%.1fC", $0) } ?? "")
}

let fanPort: Int? = optValue("--fan-port").flatMap(Int.init)
nonisolated(unsafe) let fanSignals = FanSignalHandlers()

func fanCandidates() -> [FanBackend]? {
    fanPort.map { [HTTPFanBackend(kind: $0 == HTTPFanBackend.userPort ? .userFanctl : .bundledHelper, port: $0)] }
}

/// バックエンドの状態を 1 行で(fan status / fan test / 書き出しの前後で共用)。
func fanSnapshot(_ backend: FanBackend?) -> String {
    guard let b = backend else { return "(ファン制御サービスなし)" }
    do { return fanLine(try b.status()) } catch { return "(状態を読めません: \(error.localizedDescription))" }
}

/// `body` の間だけファンを最大にする(オンのとき)。終わり・失敗・SIGTERM/SIGINT のどれでも自動に戻し、戻ったことを確認して表示する。
func withFanMax(_ on: Bool, label: String = "fan", _ body: () async throws -> Void) async throws {
    guard on else { try await body(); return }
    let (availability, g) = FanControlCenter.prepare(enabled: true, port: fanPort) { ev in
        if case .notice(let m) = ev { print("\(label): 注意 \(m)") }
        if case .released(let r) = ev { print("\(label): 解放 \(r)") }
    }
    guard let g else {
        print("\(label): 最大にしません — \(availability.reason ?? "使えません")")
        try await body(); return
    }
    fanSignals.install { print("\(label): シグナルを受信 → 自動に戻します"); fflush(stdout); FanGuardRegistry.shared.releaseAll(.signal) }
    let monitorBackend = FanBackendResolver.resolve(candidates: fanCandidates())?.backend
    print("\(label): 前    \(fanSnapshot(monitorBackend))")
    let result = g.engage()
    print("\(label): engage → \(result)")
    let monitor = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { break }
            print("\(label): 書き出し中 \(fanSnapshot(monitorBackend))")
        }
    }
    defer {
        monitor.cancel()
        let ok = g.release(.finished)
        print("\(label): 後    \(fanSnapshot(monitorBackend))  (自動に戻した=\(ok))")
    }
    try await body()
}

switch args.first {
case "info" where args.count == 2:
    do {
        let p = try Project.load(from: URL(fileURLWithPath: args[1]))
        print("size: \(p.width)x\(p.height)  fps: \(FrameRate.label(p.fps))  codec: \(p.codec)  bg: \(p.bg)")
        print("characters: \(p.characters.count)  tracks: \(p.tracks.count)")
        let clips = p.allClips
        print("clips: \(clips.count)")
        for t in ClipType.known {
            print("  \(t.rawValue): \(clips.filter { $0.type == t }.count)")
        }
        let other = clips.filter { !$0.type.isKnown }.count
        if other > 0 { print("  (unknown): \(other)") }
        // 配置(ボイスクリップ): レイヤー / 開始 / 長さ / 終了 / 直前との間隔 / キャラ / セリフ
        for (ti, t) in p.tracks.enumerated() {
            var prevEnd: Double?
            for c in t.clips.sorted(by: { $0.start < $1.start }) where c.type == .voice {
                let who = p.characters.first { $0.id == c.charId }?.name ?? "?"
                let gap = prevEnd.map { String(format: "%.3f", c.start - $0) } ?? "-"
                print(String(format: "  [layer %d] start=%.3f dur=%.3f end=%.3f gap=%@ %@: %@", ti + 1, c.start, c.duration, c.start + c.duration, gap, who, c.text ?? ""))
                prevEnd = c.start + c.duration
            }
        }
    } catch { fail("読めませんでした: \(error)") }
case "project-info" where args.count == 2:
    // project-info <file>: プロジェクトの中身(クリップ・長さ・キャラ・セリフ)を JSON で出す。読み取り専用(外部の AI が中身を見る用)
    do { print(try ProjectInfo.json(try Project.load(from: URL(fileURLWithPath: args[1])))) } catch { fail("読めませんでした: \(error)") }
case "ai" where args.count >= 2 && args[1] == "script":
    // ai script --theme T [--chars 霊夢,魔理沙] [--lines 12] (--provider-cmd "claude -p" | --provider-url http://127.0.0.1:11434 --model m) [--timeout 120] [--out file] [--show-prompt]
    // 実行したときだけ 1 回問い合わせる。クラウドの鍵は扱わない。台本の行(「名前: セリフ」)を stdout か --out に出す。
    guard let theme = optValue("--theme"), !theme.trimmingCharacters(in: .whitespaces).isEmpty else { fail("--theme が必要です") }
    let names = optValue("--chars").map { $0.split(whereSeparator: { $0 == "," || $0 == "、" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? Project.new().characters.map(\.name)
    guard !names.isEmpty else { fail("--chars が空です") }
    let timeout = optValue("--timeout").flatMap(Double.init) ?? 120
    do {
        let provider: AIProvider
        if let cmd = optValue("--provider-cmd") { provider = try CommandAIProvider(commandLine: cmd, timeout: timeout) }
        else if let url = optValue("--provider-url") { provider = try HTTPAIProvider(baseURL: url, model: optValue("--model") ?? "", timeout: timeout) }
        else { fail("--provider-cmd \"claude -p\" か --provider-url http://127.0.0.1:11434 --model <名前> が必要です") }
        let prompt = AIScriptPrompt.build(.init(theme: theme, characterNames: names, lineCount: optValue("--lines").flatMap(Int.init) ?? 12))
        if args.contains("--show-prompt") { FileHandle.standardError.write(Data(("--- 送るプロンプト ---\n" + prompt + "\n--- ここまで ---\n").utf8)) }
        let lines = try AIScriptPrompt.parse(try await provider.complete(prompt), characterNames: names)
        let text = lines.joined(separator: "\n") + "\n"
        if let out = optValue("--out") { try text.write(toFile: out, atomically: true, encoding: .utf8); print("wrote \(out) (\(lines.count) 行)") } else { print(text, terminator: "") }
    } catch { fail("AI: \(error.localizedDescription)") }
case "new" where args.count == 2:
    do { try Project.new().save(to: URL(fileURLWithPath: args[1])); print("wrote \(args[1])") }
    catch { fail("書けませんでした: \(error)") }
case "frame" where args.count >= 2:
    // frame <in.ymproj> --t <sec> --out <png> [--size WxH]
    func opt(_ name: String) -> String? { optValue(name) }
    guard let outPath = opt("--out") else { fail("--out が必要です") }
    let t = opt("--t").flatMap(Double.init) ?? 0
    do {
        var p = try Project.load(from: URL(fileURLWithPath: args[1]))
        if let s = opt("--size") {
            let sz = parseSize(s)
            p = p.scaledForResolution(newWidth: sz.0, newHeight: sz.1)
        }
        let renderer = Renderer(project: p, assets: RenderAssets())
        if let n = opt("--bench").flatMap(Int.init), n > 0 {
            // 描画時間の計測(最初の1回は暖機として除く)
            _ = renderer.renderImage(t: t)
            let t0 = Date()
            for _ in 0..<n { _ = renderer.renderImage(t: t) }
            print(String(format: "%.2f ms/frame (%d frames)", Date().timeIntervalSince(t0) * 1000 / Double(n), n))
        }
        guard let img = renderer.renderImage(t: t) else { fail("描画できませんでした") }
        let outURL = URL(fileURLWithPath: outPath)
        let fmt = StillFormat(pathExtension: outURL.pathExtension) ?? .png
        do { try StillExporter.writeImage(img, format: fmt, to: outURL) } catch { fail("\(fmt.title) を書けませんでした: \(outPath)") }
        print("wrote \(outPath) (\(p.width)x\(p.height))")
    } catch { fail("読めませんでした: \(error)") }
case "export" where args.count >= 3:
    // export <in.mcpjc> <out.mp4|out.m4a> [--range a:b|project] [--preset <組み込み名 または保存したプリセット名>] [--bitrate 8(Mbps)] [--size WxH] [--fps 29.97] [--codec h264|hevc]
    // --preset はプロジェクトの写しに当てるだけ(入力ファイルは変えない)。--size / --codec は、プリセットの前に当てる。
    do {
        var p = try Project.load(from: URL(fileURLWithPath: args[1]))
        if let s = optValue("--size") { let sz = parseSize(s); p = p.scaledForResolution(newWidth: sz.0, newHeight: sz.1) }
        if let f = optValue("--fps") { p.fps = parseFps(f) }
        if let c = optValue("--codec") { guard ["h264", "hevc"].contains(c) else { fail("--codec は h264 か hevc") }; p.codec = c }
        var preset: ExportPreset?
        var spec: ExportSpec?
        if let name = optValue("--preset") {
            // 組み込みの名前、または保存したプリセットの名前(大文字小文字は問わない)
            if let pr = ExportPreset(cliName: name) {
                preset = pr
            } else if let c = CustomExportPresetStore.load(from: CustomExportPresetStore.defaultURL()).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                spec = c.spec
            } else {
                fail("--preset は " + ExportPreset.allCases.map(\.rawValue).joined(separator: " / ") + " か、保存したプリセット名のどれか")
            }
            if (spec?.audioOnly ?? preset?.isAudioOnly) == true, !args[2].lowercased().hasSuffix(".m4a") { FileHandle.standardError.write(Data("注意: 音声のみの出力先は .m4a にしてください\n".utf8)) }
        }
        var bitrate: Double?
        if let b = optValue("--bitrate") {
            guard let v = Double(b), let ok = ExportSpec.validBitrate(v) else { fail("--bitrate は \(Int(ExportSpec.bitrateRangeMbps.lowerBound))〜\(Int(ExportSpec.bitrateRangeMbps.upperBound)) の Mbps(例 8)") }
            bitrate = ok
        }
        let range = parseRange(p)
        try await withFanMax(args.contains("--fan-max")) { try await runExport(p, to: URL(fileURLWithPath: args[2]), preset: preset, spec: spec, bitrateMbps: bitrate, range: range) }
    } catch { fail("書き出せませんでした: \(error.localizedDescription)") }
case "loudness" where args.count >= 2:
    // loudness <project> [--range a:b|project]: 書き出しと同じミックスダウンを BS.1770 で測る(読み取りのみ・自動では音量を変えない)
    do {
        let p = try Project.load(from: URL(fileURLWithPath: args[1]))
        guard let r = try LoudnessAnalysis.measure(project: p, range: parseRange(p)) else { fail("音声がありません") }
        func f(_ v: Double) -> String { v.isFinite ? String(format: "%.1f", v) : "−∞" }
        print("duration: \(String(format: "%.2f", r.duration)) s")
        print("integrated: \(f(r.integrated)) LUFS")
        print("short-term max: \(f(r.shortTermMax)) LUFS")
        print("true peak: \(f(r.truePeakDb)) dBTP")
        print("sample peak: \(f(r.samplePeakDb)) dBFS")
        if let d = r.differenceToYouTube() { print("YouTube 目安(-14 LUFS)との差: \(String(format: "%+.1f", d)) dB(目安だけ。自動では音量を変えません)") }
    } catch { fail("測れませんでした: \(error.localizedDescription)") }
case "sequence" where args.count >= 2:
    // sequence <project> --out <dir> [--format png|jpeg] [--name base] [--range a:b|project] [--fps 30] [--size WxH]
    guard let outPath = optValue("--out") else { fail("--out(出力先のフォルダ)が必要です") }
    let fmt: StillFormat
    if let f = optValue("--format") { guard let x = StillFormat(cliName: f) else { fail("--format は png か jpeg") }; fmt = x } else { fmt = .png }
    do {
        var p = try Project.load(from: URL(fileURLWithPath: args[1]))
        if let s = optValue("--size") { let sz = parseSize(s); p = p.scaledForResolution(newWidth: sz.0, newHeight: sz.1) }
        if let f = optValue("--fps") { p.fps = parseFps(f) }
        let range = parseRange(p)
        let base = optValue("--name") ?? URL(fileURLWithPath: args[1]).deletingPathExtension().lastPathComponent
        let plan = ImageSequenceExporter.plan(project: p, range: range, base: base, format: fmt)
        print("plan: \(p.width)x\(p.height) fps=\(FrameRate.label(p.fps)) frames=\(plan.frames) \(plan.first) ... \(plan.last)")
        var nextMark = 0.1
        let t0 = Date()
        let r = try await ImageSequenceExporter.export(project: p, range: range, to: URL(fileURLWithPath: outPath), base: base, format: fmt) { v in
            if v >= nextMark - 1e-9 {
                FileHandle.standardError.write(Data(String(format: "  %3.0f%%\n", v * 100).utf8))
                nextMark = (v * 10 + 1e-9).rounded(.down) / 10 + 0.1
            }
        }
        let wall = Date().timeIntervalSince(t0)
        print(String(format: "wrote %@ files=%d wall=%.2fs (%.1f fps)", outPath, r.frameCount, wall, Double(r.frameCount) / max(wall, 1e-9)))
    } catch { fail("書き出せませんでした: \(error.localizedDescription)") }
case "gif" where args.count >= 2:
    // gif <in.mcpjc> --out <x.gif> [--fps 10] [--width 480] [--range a:b|project]
    guard let outPath = optValue("--out") else { fail("--out(出力先の .gif)が必要です") }
    var options = GIFOptions.standard
    if let f = optValue("--fps") {
        guard let v = Double(f), let fps = GIFOptions.validFPS(v) else { fail("--fps は \(Int(GIFOptions.fpsRange.lowerBound))〜\(Int(GIFOptions.fpsRange.upperBound)) の数字") }
        options.fps = fps
    }
    if let w = optValue("--width") {
        guard let v = Int(w), GIFOptions.widthRange.contains(v) else { fail("--width は \(GIFOptions.widthRange.lowerBound)〜\(GIFOptions.widthRange.upperBound) の整数(px)") }
        options.maxWidth = v
    }
    do {
        let p = try Project.load(from: URL(fileURLWithPath: args[1]))
        let range = parseRange(p)
        let plan = GIFExporter.plan(project: p, range: range, options: options)
        print("plan: \(plan.width)x\(plan.height) fps=\(FrameRate.label(options.fps)) frames=\(plan.frames) delay=\(String(format: "%.3f", plan.delay))s")
        if let r = range { print(String(format: "range: %.3f - %.3f s (%.3f s)", r.start, r.end, r.duration)) }
        var nextMark = 0.1
        let t0 = Date()
        let r = try await GIFExporter.export(project: p, range: range, options: options, to: URL(fileURLWithPath: outPath)) { v in
            if v >= nextMark - 1e-9 {
                FileHandle.standardError.write(Data(String(format: "  %3.0f%%\n", v * 100).utf8))
                nextMark = (v * 10 + 1e-9).rounded(.down) / 10 + 0.1
            }
        }
        let wall = Date().timeIntervalSince(t0)
        print(String(format: "wrote %@ frames=%d bytes=%d wall=%.2fs (%.1f fps)", outPath, r.frameCount, r.bytes, wall, Double(r.frameCount) / max(wall, 1e-9)))
    } catch { fail("書き出せませんでした: \(error.localizedDescription)") }
case "subs" where args.count >= 2:
    // subs <project> --out x.srt|x.vtt: 字幕(ボイスの字幕と「字幕」レイヤーの文字)を書き出す(画面なしの確認用)
    guard let outPath = optValue("--out") else { fail("--out が必要です") }
    let outURL = URL(fileURLWithPath: outPath)
    guard let fmt = SubtitleFormat(pathExtension: outURL.pathExtension) else { fail("--out の拡張子は .srt か .vtt") }
    do {
        let p = try Project.load(from: URL(fileURLWithPath: args[1]))
        let cues = SubtitleFile.cues(from: p)
        guard !cues.isEmpty else { fail("字幕にできるクリップがありません") }
        try SubtitleFile.format(cues, as: fmt).write(to: outURL, atomically: true, encoding: .utf8)
        print("wrote \(outPath) cues=\(cues.count)")
    } catch { fail("書けませんでした: \(error)") }
case "transcribe" where args.count >= 2:
    // transcribe <media|project> --out x.srt|x.vtt [--clip 0] [--locale ja-JP]: 音声認識(オンデバイス)で字幕を作って書く(画面なしの確認用。アプリと同じ経路)。
    guard let outPath = optValue("--out") else { fail("--out が必要です") }
    guard let fmt = SubtitleFormat(pathExtension: URL(fileURLWithPath: outPath).pathExtension) else { fail("--out の拡張子は .srt か .vtt") }
    let path = args[1]
    guard FileManager.default.fileExists(atPath: path) else { fail("見つかりません: \(path)") }
    let locale = optValue("--locale") ?? "ja-JP"
    do {
        // プロジェクトなら、指定したクリップ(既定は最初の音のあるクリップ)。素材なら、その音声・動画全体。
        let ext = (path as NSString).pathExtension.lowercased()
        var clip: Clip
        var project = Project.new()
        if ext == "mcpjc" || ext == "ymproj" {
            project = try Project.load(from: URL(fileURLWithPath: path))
            let idx = optValue("--clip").flatMap(Int.init) ?? 0
            let candidates = project.allClips.filter { TranscriptionSupport.supports($0) }
            guard candidates.indices.contains(idx) else { fail("音のあるクリップが \(candidates.count) 件です(--clip は 0 から)") }
            clip = candidates[idx]
        } else {
            let kind = ClipEditing.kindOf(path: path)
            guard kind != .image else { fail("音声か動画のファイルを指定してください") }
            let dur = await ClipEditing.probeDuration(url: URL(fileURLWithPath: path), kind: kind)
            clip = ClipEditing.makeMediaClip(path: path, kind: kind, duration: dur, start: 0)
        }
        print("clip: \(clip.type.rawValue) \(String(format: "%.3f", clip.duration)) s  locale=\(locale)")
        let started = Date()
        let r = try await SubtitleTranscription.run(clip: clip, project: project, transcriber: SpeechFrameworkTranscriber(localeIdentifier: locale, requestsPermission: false),
                                                    style: nil, onProgress: { p in FileHandle.standardError.write(Data(String(format: "  %3.0f%%\n", p * 100).utf8)) })
        let cues = r.map { SubtitleFile.cues(from: $0.project) } ?? []
        guard !cues.isEmpty else { fail("認識できた文字がありませんでした") }
        try SubtitleFile.format(cues, as: fmt).write(to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)
        for c in cues { print(String(format: "  %@ --> %@  %@", SubtitleFile.timestamp(c.start, format: .srt), SubtitleFile.timestamp(c.end, format: .srt), c.text)) }
        print(String(format: "wrote %@ cues=%d wall=%.2fs", outPath, cues.count, Date().timeIntervalSince(started)))
    } catch let e as TranscriptionError {
        fail(e.errorDescription ?? "音声から字幕を作れませんでした")
    } catch { fail("音声から字幕を作れませんでした: \(error)") }
case "chapters" where args.count == 2:
    // chapters <project>: マーカーから YouTube のチャプター行を出す(注意は stderr)
    do {
        let r = Chapters.make(from: try Project.load(from: URL(fileURLWithPath: args[1])).markers)
        for w in r.warnings { FileHandle.standardError.write(Data(("注意: " + w + "\n").utf8)) }
        if r.count > 0 { print(r.text) }
    } catch { fail("読めませんでした: \(error)") }
case "speak":
    // speak (--voicevox <id> [--speed 1 --pitch 0 --intonation 1] | --voice <preset> [--speed 100]) --text "…" --out x.wav
    guard let text = optValue("--text"), let outPath = optValue("--out") else { fail("--text と --out が必要です") }
    var proj = Project.new()
    if let u = optValue("--url") { proj.voicevoxUrl = u }   // 別ポートで冷間起動を試すとき用
    let t0 = Date()
    do {
        let url: URL
        var used = ""
        if let sp = optValue("--voicevox") {
            guard let id = Int(sp) else { fail("--voicevox は話者IDの数字") }
            let engine = VoicevoxEngine()
            defer { engine.shutdown() }
            guard await engine.ensureRunning(baseURL: proj.voicevoxUrl) else { fail("VOICEVOX に接続できません(\(DependencyStatus.voicevoxURL))") }
            let t1 = Date()
            url = try await VoicevoxClient(baseURL: proj.voicevoxUrl).synthesize(text: text, speaker: id, speed: optValue("--speed").flatMap(Double.init), pitch: optValue("--pitch").flatMap(Double.init), intonation: optValue("--intonation").flatMap(Double.init))
            used = String(format: "voicevox (engine ready %.2fs, synth %.2fs)", t1.timeIntervalSince(t0), Date().timeIntervalSince(t1))
        } else if let voice = optValue("--voice") {
            let aq = AquesTalkSynthesizer()
            url = try await aq.synthesize(text: text, voice: voice, speed: optValue("--speed").flatMap(Double.init) ?? 100, commandTemplate: proj.aquestalkCommand)
            used = aq.effectiveCommand(proj.aquestalkCommand).usingFallback ? "say (fallback)" : "aquestalk"
        } else { fail("--voicevox <話者ID> か --voice <プリセット> が必要です") }
        try? FileManager.default.removeItem(atPath: outPath)
        try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: outPath))
        let dur = try RealVoiceProvider.duration(of: url)
        print(String(format: "wrote %@ engine=%@ duration=%.3fs total=%.2fs", outPath, used, dur, Date().timeIntervalSince(t0)))
    } catch { fail("合成できませんでした: \(error.localizedDescription)") }
case "speakers":
    let proj = Project.new()
    let engine = VoicevoxEngine()
    defer { engine.shutdown() }
    guard await engine.ensureRunning(baseURL: proj.voicevoxUrl) else { fail("VOICEVOX に接続できません(\(DependencyStatus.voicevoxURL))") }
    do {
        for sp in try await VoicevoxClient(baseURL: proj.voicevoxUrl).speakers() {
            print(sp.name + ": " + sp.styles.map { "\($0.name)=\($0.id)" }.joined(separator: ", "))
        }
    } catch { fail("話者を取得できませんでした: \(error.localizedDescription)") }
case "deps":
    let st = await DependencyStatus.check(project: Project.new())
    print("voicevoxInstalled: \(st.voicevoxInstalled)\nvoicevoxRunning: \(st.voicevoxRunning)\naquestalkPlayerInstalled: \(st.aquestalkPlayerInstalled)")
    for n in st.notice { print("notice: " + n) }
case "script" where args.count >= 2:
    // script <script.txt> --out <out.ymproj>: 台本ファイルから実際の声でプロジェクトを作る(既定キャラ=霊夢)
    guard let outPath = optValue("--out") else { fail("--out が必要です") }
    do {
        var p = Project.new()
        let lines = try String(contentsOfFile: args[1], encoding: .utf8).components(separatedBy: "\n")
        let provider = RealVoiceProvider(project: p)
        defer { provider.engine.shutdown() }
        try await ScriptTimeline.add(lines: lines, to: &p, voice: provider, directory: FileManager.default.temporaryDirectory, selectedCharId: p.characters[0].id)
        try p.save(to: URL(fileURLWithPath: outPath))
        print("engines used: \(provider.enginesUsed.sorted().joined(separator: ", ")); fallback: \(provider.usingFallback)")
        print("wrote \(outPath)")
    } catch { fail("作れませんでした: \(error.localizedDescription)") }
case "addvideo" where args.count == 4:
    // addvideo <in.ymproj> <clip.mp4> <out.ymproj>: 動画を、空いているレイヤー(無ければ新設)の先頭に動画クリップとして置く(再生の検証用)
    do {
        var p = try Project.load(from: URL(fileURLWithPath: args[1]))
        let url = URL(fileURLWithPath: args[2])
        let asset = AVURLAsset(url: url)
        let dur = try await asset.load(.duration).seconds
        guard dur.isFinite, dur > 0 else { fail("動画の長さを読めません: \(args[2])") }
        var c = Clip()
        c.type = .video
        c.start = 0; c.duration = dur; c.offset = 0
        c.src = url.path; c.srcDuration = dur
        c.x = 0.5; c.y = 0.5; c.scale = 1; c.opacity = 1; c.volume = 1
        var ti = p.tracks.firstIndex { $0.clips.isEmpty }
        if ti == nil { p.tracks.append(Track(name: "レイヤー\(p.tracks.count + 1)")); ti = p.tracks.count - 1 }
        p.tracks[ti!].clips.append(c)
        try p.save(to: URL(fileURLWithPath: args[3]))
        print(String(format: "added video %@ (%.2fs) to layer %d; project end=%.2fs; wrote %@", url.lastPathComponent, dur, ti! + 1, p.endTime, args[3]))
    } catch { fail("動画を足せませんでした: \(error.localizedDescription)") }
case "genclips" where args.count == 3:
    // genclips <N> <out.ymproj>: 音声なしのクリップ(文字・画像・ぼかし・ボイス風)を N 個並べた重いプロジェクト(タイムラインの描画の検証用)
    guard let n = Int(args[1]), n > 0 else { fail("N は正の整数") }
    var p = Project.new()
    for _ in 0..<5 { p.tracks.append(Track(name: "レイヤー\(p.tracks.count + 1)")) }
    let names = ["霊夢", "魔理沙", "ずんだもん"]
    for i in 0..<n {
        var c = Clip()
        let lane = i % p.tracks.count
        c.start = Double(i / p.tracks.count) * 1.7 + Double(lane) * 0.13
        c.duration = 0.4 + Double((i * 7) % 11) * 0.25
        switch i % 4 {
        case 0: c.type = .voice; c.charId = p.characters[i % 3].id; c.text = "\(names[i % 3]) のセリフ \(i)"; c.subtitle = true
        case 1: c.type = .text; c.text = "文字 \(i)"; c.fontSize = 80
        case 2: c.type = .image; c.src = "/tmp/moviecut-genclips-\(i).png"
        default: c.type = .blur; c.w = 0.3; c.h = 0.3
        }
        p.tracks[lane].clips.append(c)
    }
    do { try p.save(to: URL(fileURLWithPath: args[2])); print("wrote \(args[2]) clips=\(p.allClips.count) end=\(String(format: "%.1f", p.endTime))s") }
    catch { fail("書けませんでした: \(error)") }
case "fan":
    // fan status [--fan-port N] / fan test [--seconds 8] [--fan-port N]
    switch args.count > 1 ? args[1] : "" {
    case "status":
        let info = FanMachine.detect()
        let support = FanModelPolicy.classify(hwModel: info.hwModel, marketingName: info.marketingName)
        print("machine: \(info.hwModel ?? "?") / \(info.marketingName ?? "?") → \(support.isSupported ? "対象" : "対象外")")
        let (availability, _) = FanControlCenter.prepare(enabled: false, port: fanPort)
        print("availability: \(availability)\(availability.reason.map { " — \($0)" } ?? "")")
        let resolved = FanBackendResolver.resolve(candidates: fanCandidates())
        print("backend: \(resolved?.backend.label ?? "なし")")
        print("status: \(fanSnapshot(resolved?.backend))")
    case "test":
        let seconds = optValue("--seconds").flatMap(Double.init).map { min($0, 8) } ?? 6
        try await withFanMax(true, label: "fan-test") {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    default:
        fail("usage: moviecut-cli fan status | fan test [--seconds 8]  (--fan-port 1200|1201)")
    }
case "silence" where args.count >= 2:
    // silence <project|media> [--threshold -40] [--min 0.4] [--pad 0.1]: 無音の範囲を表示する(画面なしの確認用。ファイルは変えない)
    var params = SilenceParams()
    if let v = optValue("--threshold") { guard let d = Double(v) else { fail("--threshold は dB の数字(例: -40)") }; params.thresholdDb = d }
    if let v = optValue("--min") { guard let d = Double(v), d > 0 else { fail("--min は秒の数字(例: 0.4)") }; params.minSilence = d }
    if let v = optValue("--pad") { guard let d = Double(v), d >= 0 else { fail("--pad は秒の数字(例: 0.1)") }; params.pad = d }
    params = params.clamped
    print(String(format: "threshold=%.1f dB  min=%.2f s  pad=%.2f s", params.thresholdDb, params.minSilence, params.pad))
    func fmt(_ t: Double) -> String { String(format: "%.3f", t) }
    func report(_ c: Clip, label: String) {
        guard let prof = SilenceDetector.analyze(clip: c) else { print("\(label): 音を読めない、または対象外(速度・逆再生あり)"); return }
        let cuts = prof.silentRanges(params)
        let keeps = prof.keepRanges(params)
        let removed = cuts.reduce(0) { $0 + $1.length }
        print(String(format: "%@: duration=%.3f s  無音 %d 箇所  合計 %.3f s", label, c.duration, cuts.count, removed))
        for r in cuts { print("  silent  \(fmt(r.start)) - \(fmt(r.end))  (len \(fmt(r.length)))   timeline \(fmt(c.start + r.start)) - \(fmt(c.start + r.end))") }
        for r in keeps { print("  keep    \(fmt(r.start)) - \(fmt(r.end))") }
    }
    let path = args[1]
    let ext = (path as NSString).pathExtension.lowercased()
    do {
        if ext == "mcpjc" || ext == "ymproj" {
            let p = try Project.load(from: URL(fileURLWithPath: path))
            var n = 0
            for (ti, t) in p.tracks.enumerated() {
                for c in t.clips where Clip.supportsAudioFx(c) && c.src?.isEmpty == false {
                    n += 1
                    report(c, label: "[layer \(ti + 1)] \(c.type.rawValue) \(((c.src ?? "") as NSString).lastPathComponent) @\(fmt(c.start))")
                }
            }
            if n == 0 { fail("音のあるクリップがありません") }
        } else {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { fail("見つかりません: \(path)") }
            let kind = ClipEditing.kindOf(path: path)
            guard kind != .image else { fail("音声か動画のファイルを指定してください") }
            let dur = await ClipEditing.probeDuration(url: url, kind: kind)
            report(ClipEditing.makeMediaClip(path: path, kind: kind, duration: dur, start: 0), label: url.lastPathComponent)
        }
    } catch { fail("読めませんでした: \(error)") }
case "smoke":
    // smoke --out <mp4> [--size WxH] [--codec h264|hevc] [--blur]
    guard let outPath = optValue("--out") else { fail("--out が必要です") }
    do {
        // --save-project のときは、音声をプロジェクトの隣に残す(消すとリンク切れになる)
        let keepAudio = optValue("--save-project")
        let dir = keepAudio.map { URL(fileURLWithPath: $0).deletingPathExtension().appendingPathExtension("voices") }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("moviecut-smoke-\(UUID().uuidString)")
        defer { if keepAudio == nil { try? FileManager.default.removeItem(at: dir) } }
        let size = optValue("--size").map(parseSize)
        let codec = optValue("--codec")
        if let c = codec, !["h264", "hevc"].contains(c) { fail("--codec は h264 か hevc") }
        let real = RealVoiceProvider(project: Project.new())
        defer { real.engine.shutdown() }
        let useTone = args.contains("--tone")
        let voice: VoiceProvider = useTone ? ToneVoiceProvider() : real
        var p = try await ScriptTimeline.smokeProject(size: size.map { (width: $0.0, height: $0.1) }, codec: codec, blur: args.contains("--blur"), voice: voice, directory: dir)
        print(useTone ? "voices: tone (--tone)" : "voices: engines used = \(real.enginesUsed.sorted().joined(separator: ", ")); fallback = \(real.usingFallback)")
        // 計測用: 文字とぼかしの長さを伸ばす(--text-duration 10)
        if let d = optValue("--text-duration").flatMap(Double.init) {
            for ti in p.tracks.indices { for ci in p.tracks[ti].clips.indices where p.tracks[ti].clips[ci].type == .text || p.tracks[ti].clips[ci].type == .blur { p.tracks[ti].clips[ci].duration = d } }
        }
        if let f = optValue("--fps") { p.fps = parseFps(f) }
        if let sp = optValue("--save-project") { try p.save(to: URL(fileURLWithPath: sp)) }  // frame コマンドとの比較用
        print("clips: " + p.allClips.map { "\($0.type.rawValue)(\(String(format: "%.2f", $0.duration)))" }.joined(separator: " "))
        try await runExport(p, to: URL(fileURLWithPath: outPath))
    } catch { fail("書き出せませんでした: \(error.localizedDescription)") }
default:
    fail("usage:\n  moviecut-cli info <file.ymproj>\n  moviecut-cli new <out.ymproj>\n  moviecut-cli export <in.mcpjc> <out.mp4|out.m4a> [--range a:b|project] [--preset youtube1080|youtube1080p60|youtube4k|short|shorts|tiktok|reels|x720|x1080|light|audio|<保存したプリセット名>] [--bitrate 8(Mbps)] [--size WxH] [--fps 29.97] [--codec h264|hevc] [--fan-max [--fan-port 1200|1201]]\n  moviecut-cli fan status | fan test [--seconds 8] [--fan-port 1200|1201]\n  moviecut-cli smoke --out <mp4> [--size WxH] [--fps 23.976] [--codec h264|hevc] [--blur] [--tone] [--save-project p.ymproj]\n  moviecut-cli speak (--voicevox <id> [--speed --pitch --intonation] | --voice <preset> [--speed]) --text <t> --out <wav>\n  moviecut-cli speakers | deps | script <script.txt> --out <p.ymproj>\n  moviecut-cli frame <in.ymproj> --t <sec> --out <png|jpg> [--size WxH] [--bench N]\n  moviecut-cli gif <in.mcpjc> --out <x.gif> [--fps 10] [--width 480] [--range a:b|project]\n  moviecut-cli sequence <in.mcpjc> --out <dir> [--format png|jpeg] [--name base] [--range a:b|project] [--fps 30] [--size WxH]\n  moviecut-cli addvideo <in.ymproj> <clip.mp4> <out.ymproj>\n  moviecut-cli genclips <N> <out.ymproj>\n  moviecut-cli silence <project|media> [--threshold -40] [--min 0.4] [--pad 0.1]\n  moviecut-cli subs <project> --out <x.srt|x.vtt>\n  moviecut-cli transcribe <media|project> --out <x.srt|x.vtt> [--clip 0] [--locale ja-JP]\n  moviecut-cli chapters <project>\n  moviecut-cli loudness <project> [--range a:b|project]\n  moviecut-cli project-info <project>   (JSON。読み取り専用)\n  moviecut-cli ai script --theme <t> [--chars 霊夢,魔理沙] [--lines 12] (--provider-cmd \"claude -p\" | --provider-url http://127.0.0.1:11434 --model <m>) [--timeout 120] [--out x.txt] [--show-prompt]")
}
