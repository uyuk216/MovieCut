import Foundation
import AVFoundation

/// キャラのエンジンに応じて VOICEVOX / AquesTalk(または say)で合成する本物の VoiceProvider。
public final class RealVoiceProvider: VoiceProvider {
    public let voicevoxURL: String
    public let aquestalkCommand: String
    public let voicevox: VoicevoxClient
    public let aquestalk: AquesTalkSynthesizer
    public let engine: VoicevoxEngine
    /// 使われたエンジンの記録("voicevox" / "aquestalk" / "say")。
    public private(set) var enginesUsed: Set<String> = []
    private let lock = NSLock()

    public init(project: Project, cache: VoiceCache = .standard, engine: VoicevoxEngine = VoicevoxEngine(), aquestalk: AquesTalkSynthesizer? = nil, session: URLSession = .shared) {
        self.voicevoxURL = project.voicevoxUrl
        self.aquestalkCommand = project.aquestalkCommand
        self.voicevox = VoicevoxClient(baseURL: project.voicevoxUrl, cache: cache, session: session)
        self.aquestalk = aquestalk ?? AquesTalkSynthesizer(cache: cache)
        self.engine = engine
    }

    /// say で代用しているか(UI の警告用)。
    public var usingFallback: Bool { aquestalk.effectiveCommand(aquestalkCommand).usingFallback }

    public func synthesize(character: Character, text: String, in directory: URL) async throws -> VoiceResult {
        let url: URL
        if character.engine == "voicevox" {
            guard await engine.ensureRunning(baseURL: voicevoxURL) else {
                throw VoiceError.message("VOICEVOX に接続できません。VOICEVOX をインストールして起動してください(\(DependencyStatus.voicevoxURL))。")
            }
            url = try await voicevox.synthesize(text: text, speaker: character.speaker ?? 3, speed: character.speed, pitch: character.pitch, intonation: character.intonation)
            lock.withLock { _ = enginesUsed.insert("voicevox") }
        } else {
            url = try await aquestalk.synthesize(text: text, voice: character.voice, speed: character.speed, commandTemplate: aquestalkCommand)
            lock.withLock { _ = enginesUsed.insert(usingFallback ? "say" : "aquestalk") }
        }
        return VoiceResult(url: url, duration: try wavDuration(url))
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
    public static func regenerateVoice(clip: inout Clip, project: Project, provider: VoiceProvider, directory: URL = FileManager.default.temporaryDirectory) async throws {
        guard let ch = project.characters.first(where: { $0.id == (clip.charId ?? "") }) else { return }
        let r = try await provider.synthesize(character: ch, text: clip.text ?? "", in: directory)
        clip.src = r.url.path
        clip.duration = clipDuration(forAudio: r.duration)
        clip.offset = 0
    }
}

/// 自由関数版(仕様の `regenerateVoice(clip:project:provider:)`)。
public func regenerateVoice(clip: inout Clip, project: Project, provider: VoiceProvider) async throws {
    try await ScriptTimeline.regenerateVoice(clip: &clip, project: project, provider: provider)
}
