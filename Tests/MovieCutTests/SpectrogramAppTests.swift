import XCTest
import AVFoundation
import MovieCutCore
@testable import MovieCut

/// スペクトログラム(アプリ側): スコープシートが使う選択中クリップの対象判定、
/// 英訳の有無、プロジェクト保存へ解析結果が混ざらないこと。
@MainActor
final class SpectrogramAppTests: XCTestCase {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spectrogram-app-tests-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func clip(_ id: String, _ type: ClipType, src: String?, dur: Double = 3) -> Clip {
        var c = Clip(); c.id = id; c.type = type; c.src = src; c.duration = dur
        return c
    }

    private func makeModel() -> ProjectModel {
        var p = Project.new()
        p.tracks[0].clips = [clip("a", .audio, src: "/tmp/tone.wav"), clip("i", .image, src: "/tmp/pic.png")]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        return m
    }

    func testSelectedAudioClipIsSpectrogramTarget() {
        let m = makeModel()
        m.selectedClipId = "a"
        let selected = m.selectedClip
        XCTAssertNotNil(selected)
        XCTAssertTrue(selected.map { Spectrogram.supports($0) } ?? false, "音声クリップを選べば対象")
        m.selectedClipId = "i"
        XCTAssertFalse(m.selectedClip.map { Spectrogram.supports($0) } ?? true, "画像クリップは対象外")
        m.selectedClipId = nil
        XCTAssertNil(m.selectedClip, "未選択ではシートは案内文を出す")
    }

    func testSpectrogramStringsHaveEnglish() {
        for ja in [
            "スペクトログラム(横: 時間 / 縦: 周波数・対数 / 色: 強さ)",
            "音のあるクリップ(音声・ボイス・動画)を選んでから開くと、スペクトログラムが出ます。",
            "選択中のクリップに音声が無いため、スペクトログラムは出せません。",
            "スペクトログラムを計算しています…",
            "スペクトログラムを計算できませんでした。",
            "いちばん強い周波数",
            "解析した長さ",
            "長いクリップのため、先頭だけを解析しました。",
        ] {
            XCTAssertTrue(L10n.hasEnglish(ja), "英訳がある: \(ja)")
        }
    }

    func testSelectedClipAnalyzesEndToEndViaCache() throws {
        // 実際に WAV を置いた音声クリップを選び、シートと同じ経路(共有キャッシュ)で解析する
        let url = tmp.appendingPathComponent("tone.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            // 書き込み用ファイルは閉じてから読む(開いたままだとヘッダが確定せず読めない)
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let total = 48000
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
            buf.frameLength = AVAudioFrameCount(total)
            for i in 0..<total { buf.floatChannelData![0][i] = 0.5 * Float(sin(2 * .pi * 440 * Double(i) / 48000)) }
            try file.write(from: buf)
        }

        var p = Project.new()
        p.tracks[0].clips = [clip("a", .audio, src: url.path, dur: 1)]
        let m = ProjectModel(project: p)
        m.notices = OneTimeNotices()
        m.selectedClipId = "a"
        let selected = try XCTUnwrap(m.selectedClip)
        let result = try XCTUnwrap(SpectrogramCache.shared.spectrogram(clip: selected))
        let dom = try XCTUnwrap(result.dominantFrequency())
        XCTAssertEqual(dom, 440, accuracy: 15, "支配周波数: \(dom)")
    }

    func testProjectEncodingHasNoSpectrogramData() throws {
        // 表示専用の解析結果はプロジェクト保存へ入れない(保存バイト不変の担保)
        let m = makeModel()
        let data = try JSONEncoder().encode(m.project)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("spectrogram"), "保存形式にスペクトログラムの項目は無い")
        XCTAssertFalse(text.contains("スペクトログラム"))
    }
}
