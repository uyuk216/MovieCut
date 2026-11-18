import Foundation
import AVFoundation

/// キャラのエンジンに応じて VOICEVOX / AquesTalk(または say)で合成する本物の VoiceProvider。
public final class RealVoiceProvider: VoicevoxAccentProviding {
    public let voicevoxURL: String
    public let voicevox: VoicevoxClient
    public let aquestalk: AquesTalkSynthesizer
    public let engine: VoicevoxEngine
    /// 使われたエンジンの記録("voicevox" / "aquestalk" / "say")。
    public private(set) var enginesUsed: Set<String> = []
    private let lock = NSLock()

    public init(project: Project, cache: VoiceCache = .standard, engine: VoicevoxEngine = VoicevoxEngine(), aquestalk: AquesTalkSynthesizer? = nil, session: URLSession = .shared, policy: VoiceEndpointPolicy = .current) {
        self.voicevoxURL = project.voicevoxUrl
        self.voicevox = VoicevoxClient(baseURL: project.voicevoxUrl, cache: cache, session: session, policy: policy)
        self.aquestalk = aquestalk ?? AquesTalkSynthesizer(cache: cache, forbiddenRoots: Self.mediaFolders(of: project))
        self.engine = engine
    }

    /// プロジェクトの素材があるフォルダ(ここにある実行ファイルは使わない)。
    static func mediaFolders(of project: Project) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for c in project.allClips {
            guard let src = c.src, src.hasPrefix("/") else { continue }
            let dir = URL(fileURLWithPath: src).deletingLastPathComponent()
            if dir.path != "/", seen.insert(dir.path).inserted { out.append(dir) }
        }
        return out
    }

    /// say で代用しているか(UI の警告用)。
    public var usingFallback: Bool { aquestalk.usingFallback }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        try await synthesize(character: character, text: text, accentPhrases: nil, in: directory)
    }

    /// アクセント句つき合成。VOICEVOX のキャラだけ accent_phrases を差し替え、AquesTalk などは通常合成に落とす。
    public func synthesizeWithAccent(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase], in directory: URL) async throws -> VoiceResult {
        try await synthesize(character: character, text: text, accentPhrases: character.engine == "voicevox" ? accentPhrases : nil, in: directory)
    }

    private func synthesize(character: Character, text: String, accentPhrases: [VoicevoxAccentPhrase]?, in directory: URL) async throws -> VoiceResult {
        let url: URL
        if character.engine == "voicevox" {
            _ = try voicevox.validatedBaseURL()   // 送ってよい先か(だめなら日本語の理由で止める)
            guard await engine.ensureRunning(baseURL: voicevoxURL) else {
                throw VoiceError.message("VOICEVOX に接続できません。VOICEVOX をインストールして起動するか、インスペクタでこのキャラの音声エンジンを「ゆっくり (AquesTalk)」に切り替えてください(\(DependencyStatus.voicevoxURL))。")
            }
            url = try await voicevox.synthesize(text: text, speaker: character.speaker ?? 3, speed: character.speed, pitch: character.pitch, intonation: character.intonation, prePhonemeLength: character.prePhonemeLength, postPhonemeLength: character.postPhonemeLength, pauseLengthScale: character.pauseLengthScale, accentPhrases: accentPhrases)
            lock.withLock { _ = enginesUsed.insert("voicevox") }
            // あいうえお口パク用のモーラタイミングは、合成の返却を待たせないよう切り離して取得する(ベストエフォート)
            scheduleVoicevoxSidecar(wavURL: url, text: text, character: character)
        } else {
            url = try await aquestalk.synthesize(text: text, voice: character.voice, speed: character.speed)
            lock.withLock { _ = enginesUsed.insert(usingFallback ? "say" : "aquestalk") }
        }
        return VoiceResult(url: url, duration: try wavDuration(url))
    }

    // MARK: サイドカー(モーラタイミング)の切り離し取得

    /// サイドカー取得が処理中のパス(同じ WAV への多重スケジュールを抑止する)。
    private static let sidecarLock = NSLock()
    private static var sidecarInFlight: Set<String> = []

    /// 処理を呼び出し元から切り離して実行する。呼び出しは即座に返り、処理の成否・所要時間・例外は呼び出し元に影響しない。
    @discardableResult
    static func scheduleSidecar(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task.detached { await operation() }
    }

    /// VOICEVOX のモーラタイミングをサイドカーへ保存する処理をスケジュールする(合成本体からは await しない)。
    /// 既に有効なサイドカーがあれば何もしない。無い・壊れている場合は取得し、.atomic で書く(壊れた既存ファイルは上書きして直す)。
    private func scheduleVoicevoxSidecar(wavURL: URL, text: String, character: Character) {
        let sidecar = VoicevoxMora.sidecarURL(forWav: wavURL.path)
        Self.sidecarLock.lock()
        guard Self.sidecarInFlight.insert(sidecar.path).inserted else { Self.sidecarLock.unlock(); return }
        Self.sidecarLock.unlock()
        let client = voicevox
        let speaker = character.speaker ?? 3
        let speed = character.speed, pitch = character.pitch, intonation = character.intonation
        let pre = character.prePhonemeLength, post = character.postPhonemeLength, pause = character.pauseLengthScale
        Self.scheduleSidecar {
            defer {
                Self.sidecarLock.lock(); Self.sidecarInFlight.remove(sidecar.path); Self.sidecarLock.unlock()
            }
            if let existing = try? Data(contentsOf: sidecar), VoicevoxMora.decodeSidecar(existing) != nil { return }
            guard let segs = try? await client.moraTimeline(text: text, speaker: speaker, speed: speed, pitch: pitch, intonation: intonation, pre: pre, post: post, pause: pause),
                  !segs.isEmpty, let data = VoicevoxMora.encodeSidecar(segs) else { return }
            try? data.write(to: sidecar, options: .atomic)
        }
    }

    /// WAV の長さ(秒)。
    public func wavDuration(_ url: URL) throws -> Double { try RealVoiceProvider.duration(of: url) }
    public static func duration(of url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }
}

extension ScriptTimeline {
    /// ボイスクリップの長さ = 音声の長さ + 0.15 秒。
    public static func clipDuration(forAudio seconds: Double) -> Double { seconds + 0.15 }

    /// 音声を作り直す(セリフやキャラを変えたとき)。新しい src、長さ = 音声 + 0.15、offset は 0 に戻す。
    ///
    /// 読み辞書(`project.readingDictionary`)は合成の直前に適用する(`DictionaryVoiceProvider`)。
    /// 優先順位(仕様):
    ///  1. 土台は `clip.text`(セリフごとの読み指定。ユーザーが手で書いた読みがそのまま土台)。
    ///  2. 辞書は合成直前にその上へ当てる最終変換。かなで書いた明示の読みは、辞書の表記キーと一致しない限り
    ///     書き換わらないので、実質セリフごとの読みが優先され、辞書は残った表記を補う。
    ///  3. 台本由来のクリップは `ScriptTimeline.add` が生成時に辞書を焼き込み済み。通常の辞書(漢字表記→かな)なら
    ///     読み文字列はキーに一致しないため、再合成で再適用しても結果は変わらない。
    /// `clip.text` と字幕は書き換えない(合成に渡す文だけ変換する)。辞書が空なら従来と完全に同一。
    public static func regenerateVoice(clip: inout Clip, project: Project, provider: VoiceProvider, directory: URL = FileManager.default.temporaryDirectory) async throws {
        guard let ch = project.characters.first(where: { $0.id == (clip.charId ?? "") }) else { return }
        let voice = DictionaryVoiceProvider(inner: provider, entries: project.readingDictionary)
        let body = ExpressionTag.body(clip.text ?? "")
        let r: VoiceResult
        if let accent = clip.voicevoxAccent, !accent.isEmpty,
           shouldUseAccent(bodyText: body, entries: project.readingDictionary),
           provider is any VoicevoxAccentProviding {
            r = try await voice.synthesizeWithAccent(character: ch, text: body, accentPhrases: accent, in: directory)
        } else {
            r = try await voice.synthesize(character: ch, text: body, in: directory)
        }
        clip.src = r.url.path
        clip.duration = clipDuration(forAudio: r.duration)
        clip.offset = 0
    }
}

extension ScriptTimeline {
    /// 保存済みアクセントを再合成に使ってよいか(純粋関数)。
    /// 辞書を適用した後のテキストが元のテキストと完全一致するときだけ true。
    /// 辞書で読み上げ文が変わったら false を返し、呼び出し側はアクセントを使わず通常合成に落とす。
    /// 落とす理由: アクセント句は元のテキストの解析結果で、VOICEVOX のモーラはカナ表記のため漢字まじりの
    /// テキストと直接照合できない。緩い検証では句とのずれを検出できないので、変換が入ったら使わないと決めた。
    public static func shouldUseAccent(bodyText: String, entries: [ReadingEntry]) -> Bool {
        entries.isEmpty || ReadingDictionary.apply(to: bodyText, entries: entries) == bodyText
    }
}

/// 自由関数版(仕様の `regenerateVoice(clip:project:provider:)`)。
public func regenerateVoice(clip: inout Clip, project: Project, provider: VoiceProvider) async throws {
    try await ScriptTimeline.regenerateVoice(clip: &clip, project: project, provider: provider)
}
