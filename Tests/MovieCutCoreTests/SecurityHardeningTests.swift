import XCTest
@testable import MovieCutCore

/// 静的セキュリティ調査(2026-11-05)の対応: 外部実行ファイルの出所・音声サーバーの送信先・外部入力の検証。
final class SecurityHardeningTests: XCTestCase {
    var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        chmod(tmp.path, 0o755)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    @discardableResult
    func makeFile(_ name: String, _ body: String = "#!/bin/sh\nexit 0\n", mode: mode_t = 0o755, in dir: URL? = nil) throws -> URL {
        let d = dir ?? tmp!
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent(name)
        try Data(body.utf8).write(to: u)
        chmod(u.path, mode)
        return u
    }

    /// 乱数(固定シード)。
    struct Rng: RandomNumberGenerator {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: (4) VOICEVOX の送信先

    func testLocalEndpointsAllowedByDefault() throws {
        let p = VoiceEndpointPolicy()
        for u in ["http://127.0.0.1:50021", "http://localhost:50021", "http://[::1]:50021", "http://LOCALHOST:1/"] {
            XCTAssertNoThrow(try p.validate(u), u)
        }
    }

    func testRemoteEndpointsRefusedByDefaultWithJapaneseMessage() {
        let p = VoiceEndpointPolicy()
        for u in ["http://example.com:50021", "https://voice.example.com", "http://192.168.0.5:50021",
                  "http://localhost.evil.com:50021", "http://127.0.0.1.evil.com", "http://127.0.0.1@evil.com:50021",
                  "http://user:pw@127.0.0.1:50021", "ftp://127.0.0.1", "file:///etc/passwd", "", "not a url", "http://"] {
            XCTAssertThrowsError(try p.validate(u), u) { err in
                XCTAssertFalse(err.localizedDescription.isEmpty)
            }
        }
        do { try p.validate("http://example.com:50021"); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("リモートの音声サーバーを許可"))
        }
    }

    func testRemoteNeedsToggleAndAllowedHost() throws {
        // 許可をオンにしても、許可したホスト以外(= プロジェクトファイルに書かれた別のホスト)には送らない
        let on = VoiceEndpointPolicy(allowRemote: true, allowedHosts: [])
        XCTAssertThrowsError(try on.validate("http://example.com"))
        let host = VoiceEndpointPolicy(allowRemote: true, allowedHosts: ["Voice.Example.com"])
        XCTAssertNoThrow(try host.validate("https://voice.example.com:8443"))
        XCTAssertThrowsError(try host.validate("https://evil.example.com"))
        // 許可ホストを書いてあっても、スイッチがオフなら送らない
        let off = VoiceEndpointPolicy(allowRemote: false, allowedHosts: ["voice.example.com"])
        XCTAssertThrowsError(try off.validate("https://voice.example.com"))
    }

    func testSettingsAreStoredInDefaultsNotProject() throws {
        let d = UserDefaults(suiteName: "sec-test-\(UUID().uuidString)")!
        XCTAssertFalse(SecuritySettings.allowRemoteVoice(d))
        SecuritySettings.setAllowRemoteVoice(true, to: d)
        SecuritySettings.setRemoteVoiceHosts("A.example.com, b.example.com\nA.example.com", to: d)
        XCTAssertTrue(SecuritySettings.allowRemoteVoice(d))
        XCTAssertEqual(SecuritySettings.remoteVoiceHosts(d), ["a.example.com", "b.example.com"])
        SecuritySettings.setAllowRemoteVoice(false, to: d)
        XCTAssertFalse(SecuritySettings.allowRemoteVoice(d))
        // プロジェクトの JSON にはこれらのキーが出ない
        let json = String(decoding: try Project.new().encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("allowRemote")); XCTAssertFalse(json.contains("security."))
    }

    func testVoicevoxClientNeverSendsToProjectUrlRemote() async throws {
        FakeVoicevox.calls = []
        let client = VoicevoxClient(baseURL: "http://evil.example.com:50021", cache: VoiceCache(directory: tmp), session: FakeVoicevox.session(), policy: VoiceEndpointPolicy())
        do { _ = try await client.synthesize(text: "秘密のセリフ", speaker: 1); XCTFail("送ってはいけない") } catch {
            XCTAssertTrue(error.localizedDescription.contains("リモートの音声サーバーを許可"))
        }
        do { _ = try await client.speakers(); XCTFail() } catch {}
        XCTAssertTrue(FakeVoicevox.calls.isEmpty, "通信していない")
        let alive = await VoicevoxEngine.isAlive(baseURL: "http://evil.example.com:50021", policy: VoiceEndpointPolicy())
        XCTAssertFalse(alive)
    }

    func testRealVoiceProviderRefusesRemoteProjectUrl() async throws {
        FakeVoicevox.calls = []
        var p = Project.new()
        p.voicevoxUrl = "http://evil.example.com:50021"
        let provider = RealVoiceProvider(project: p, cache: VoiceCache(directory: tmp), engine: VoicevoxEngine(binaryPath: "/nonexistent/run"),
                                         session: FakeVoicevox.session(), policy: VoiceEndpointPolicy())
        var ch = Character(); ch.engine = "voicevox"; ch.speaker = 3
        do { _ = try await provider.synthesize(character: ch, text: "あ", in: tmp); XCTFail() } catch {
            XCTAssertTrue(error.localizedDescription.contains("リモート"))
        }
        XCTAssertTrue(FakeVoicevox.calls.isEmpty)
    }

    func testProjectFileKeepsRemoteUrlButItIsInert() throws {
        // 古いファイルはそのまま読み書きできる(値は保つ)が、送信側が断る
        let raw = Data(#"{"voicevoxUrl":"http://evil.example.com:50021","aquestalkCommand":"touch /tmp/pwned"}"#.utf8)
        let p = try Project.decode(from: raw)
        XCTAssertEqual(p.voicevoxUrl, "http://evil.example.com:50021")
        XCTAssertEqual(p.aquestalkCommand, "touch /tmp/pwned")
        XCTAssertThrowsError(try VoiceEndpointPolicy().validate(p.voicevoxUrl))
    }

    // MARK: (1) 実行ファイルの出所

    func testExecutableTrustAcceptsPlainExecutable() throws {
        let f = try makeFile("player")
        guard case .success = ExecutableTrust.validate(path: f.path) else { return XCTFail() }
        guard case .success = ExecutableTrust.validate(path: "/bin/ls") else { return XCTFail() }
    }

    func testExecutableTrustRejections() throws {
        func why(_ p: String, _ roots: [URL] = []) -> ExecutableTrust.Rejection? {
            if case .failure(let r) = ExecutableTrust.validate(path: p, forbiddenRoots: roots) { return r }
            return nil
        }
        XCTAssertEqual(why("relative/path"), .notAbsolute)
        XCTAssertEqual(why(tmp.path + "/../etc/x"), .traversal)
        XCTAssertEqual(why(tmp.path + "/none"), .notFound)
        let real = try makeFile("real")
        let link = tmp.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(why(link.path), .symlink)
        let ww = try makeFile("ww", mode: 0o777)
        XCTAssertEqual(why(ww.path), .writableByOthers)
        let gw = try makeFile("gw", mode: 0o775)
        XCTAssertEqual(why(gw.path), .writableByOthers)
        let nx = try makeFile("nx", mode: 0o644)
        XCTAssertEqual(why(nx.path), .notExecutable)
        XCTAssertEqual(why(tmp.path), .notRegular)
        let open = tmp.appendingPathComponent("openDir")
        try FileManager.default.createDirectory(at: open, withIntermediateDirectories: true)
        let inOpen = try makeFile("p", in: open)
        chmod(open.path, 0o777)
        XCTAssertEqual(why(inOpen.path), .writableByOthers, "親フォルダが誰でも書ける")
        chmod(open.path, 0o755)
        // プロジェクト・素材のフォルダの中は実行しない(シンボリックリンク経由の別名でも)
        let proj = tmp.appendingPathComponent("MyProject")
        let planted = try makeFile("AquesTalkPlayer", in: proj)
        if case .insideProject = why(planted.path, [proj]) ?? .notFound {} else { XCTFail("プロジェクト内") }
        let alias = tmp.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: proj)
        if case .insideProject = why(alias.appendingPathComponent("AquesTalkPlayer").path, [proj]) ?? .notFound {} else { XCTFail("別名経由") }
    }

    func testLocatorUsesOnlyFixedLocations() throws {
        let project = tmp.appendingPathComponent("Project")
        let media = try makeFile("AquesTalkPlayer", in: project)       // プロジェクト内に置かれた実行ファイル
        let support = tmp.appendingPathComponent("Support")
        let cands = AquesTalkLocator.candidates(userSetting: nil, bundleResources: URL(fileURLWithPath: "/nonexistent/Resources"), supportRoot: support, home: tmp.path + "/home")
        XCTAssertFalse(cands.contains { $0.hasPrefix(project.path) }, "プロジェクト由来のパスは候補にならない")
        XCTAssertEqual(cands, ["/nonexistent/Resources/AquesTalk/AquesTalkPlayer", support.path + "/AquesTalk/AquesTalkPlayer",
                               "/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer", tmp.path + "/home/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer"])
        _ = media
        // 固定の場所に置いたものは使える
        let planted = try makeFile("AquesTalkPlayer", in: support.appendingPathComponent("AquesTalk"))
        let got = AquesTalkLocator.resolve(userSetting: nil, bundleResources: nil, supportRoot: support, home: tmp.path + "/home")
        XCTAssertEqual(got?.resolvingSymlinksInPath().path, planted.resolvingSymlinksInPath().path)
        // 利用者の設定が危険(誰でも書ける)なら、そこは使わない
        let bad = try makeFile("bad", mode: 0o777)
        let got2 = AquesTalkLocator.resolve(userSetting: bad.path, bundleResources: nil, supportRoot: support, home: tmp.path + "/home")
        XCTAssertEqual(got2?.lastPathComponent, "AquesTalkPlayer")
        XCTAssertNotEqual(got2?.path, bad.path)
        // 設定したファイルがプロジェクトのフォルダの中なら使わない
        let setting = try makeFile("mine", in: project)
        let got3 = AquesTalkLocator.resolve(userSetting: setting.path, bundleResources: nil, supportRoot: support, home: tmp.path + "/home", forbiddenRoots: [project])
        XCTAssertNotEqual(got3?.lastPathComponent, "mine")
    }

    func testSynthesizerRunsOnlyResolvedExecutableWithArrayArguments() async throws {
        let log = tmp.appendingPathComponent("args.log")
        // -W の次の引数に WAV を書き、受け取った引数を 1 行ずつ記録するスクリプト
        let script = try makeFile("player", """
        #!/bin/sh
        for a in "$@"; do printf '%s\\n' "$a" >> '\(log.path)'; done
        while [ "$1" != "-W" ]; do shift; done
        echo RIFFfake > "$2"
        """)
        let pwned = tmp.appendingPathComponent("pwned")
        var proj = Project.new()
        proj.aquestalkCommand = "touch \(pwned.path)"          // プロジェクト由来のコマンドは無視される
        let aq = AquesTalkSynthesizer(cache: VoiceCache(directory: tmp.appendingPathComponent("v")), playerPath: script.path)
        let out = try await aq.synthesize(text: "a'; touch \(pwned.path); '", voice: "女声1", speed: 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pwned.path), "シェルを通さない")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[3], "a'; touch \(pwned.path); '")
        // 危険なプレーヤー(誰でも書ける)は使わず、say に代わる
        let bad = try makeFile("badplayer", mode: 0o777)
        XCTAssertTrue(AquesTalkSynthesizer(cache: VoiceCache(directory: tmp), playerPath: bad.path).usingFallback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pwned.path))
        _ = proj
    }

    func testMediaFoldersOfProject() {
        var p = Project.new()
        var c = Clip(); c.src = "/Users/x/素材/a.mp4"
        p.tracks[0].clips = [c]
        XCTAssertEqual(RealVoiceProvider.mediaFolders(of: p).map(\.path), ["/Users/x/素材"])
    }

    func testAICommandAndImageCommandAreUserSettingOnlyArrays() throws {
        // AI コマンドは UserDefaults の設定だけから作る(プロジェクトには項目が無い)。引数は配列。
        let json = String(decoding: try Project.new().encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("ai.command")); XCTAssertFalse(json.contains("aiImage"))
        let p = try CommandAIProvider(commandLine: "/bin/echo 'a b' c", timeout: 5)
        XCTAssertEqual(p.executable, "/bin/echo")
        XCTAssertEqual(p.arguments, ["a b", "c"])
    }

    // MARK: (3) 入力の検証

    func testProjectSizeCapDepthCapAndCounts() throws {
        let big = Data(repeating: 0x20, count: InputLimits.maxProjectBytes + 1)
        XCTAssertThrowsError(try Project.decode(from: big)) { XCTAssertEqual($0 as? InputLimits.Failure, .tooLarge(what: "プロジェクトファイル", limit: InputLimits.maxProjectBytes)) }
        let deep = Data(String(repeating: "[", count: 200_000).utf8)
        XCTAssertThrowsError(try Project.decode(from: deep)) { XCTAssertEqual($0 as? InputLimits.Failure, .tooDeep) }
        let deepObj = Data((String(repeating: #"{"a":"#, count: 5000) + "1" + String(repeating: "}", count: 5000)).utf8)
        XCTAssertThrowsError(try Project.decode(from: deepObj))
        // 文字列の中の括弧は深さに数えない
        XCTAssertTrue(InputLimits.jsonDepthWithinLimit(Data((#"{"a":""# + String(repeating: "[", count: 1000) + #""}"#).utf8)))
        let tracks = (0..<(InputLimits.maxTracks + 1)).map { _ in #"{"id":"t","name":"x","clips":[]}"# }.joined(separator: ",")
        XCTAssertThrowsError(try Project.decode(from: Data(#"{"tracks":[\#(tracks)]}"#.utf8))) { XCTAssertEqual($0 as? InputLimits.Failure, .tooMany("レイヤー")) }
    }

    func testProjectLoadClampsAbsurdNumbers() throws {
        let raw = #"""
        {"width":2000000000,"height":-5,"fps":1e300,"rangeIn":1e300,
         "tracks":[{"id":"t","name":"x","clips":[{"id":"c","type":"video","start":1e300,"duration":-1e300,"offset":1e99,"x":1e300,"fontSize":1e300,"blur":1e300,"speed":1e300}]}]}
        """#
        let p = try Project.decode(from: Data(raw.utf8))
        XCTAssertEqual(p.width, InputLimits.maxPixelSide); XCTAssertEqual(p.height, 1)
        XCTAssertLessThanOrEqual(p.fps, 240)
        XCTAssertEqual(p.rangeIn, InputLimits.maxSeconds)
        let c = p.tracks[0].clips[0]
        XCTAssertEqual(c.start, InputLimits.maxSeconds); XCTAssertEqual(c.duration, -InputLimits.maxSeconds); XCTAssertEqual(c.offset, InputLimits.maxSeconds)
        XCTAssertEqual(c.x, 1e5); XCTAssertEqual(c.fontSize, 4000); XCTAssertEqual(c.blur, 2000); XCTAssertEqual(c.speed, 1000)
    }

    func testSaneProjectIsUntouchedByClamps() throws {
        for name in ["rich", "electron-made", "timeline", "effects", "speed"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "ymproj", subdirectory: "Fixtures"))
            let data = try Data(contentsOf: url)
            let loaded = try Project.decode(from: data)
            var raw = try JSONDecoder().decode(Project.self, from: data)   // サニタイズなしの素の読み込み
            raw.characters = loaded.characters                              // 既定のキャラは読むたびに新しい id が付く
            XCTAssertEqual(loaded, raw, name)
            try raw.sanitizeLoaded()
            XCTAssertEqual(try loaded.encoded(), try raw.encoded(), name)
        }
    }

    func testProjectLoadRejectsHugeFileWithoutReadingIt() throws {
        let f = tmp.appendingPathComponent("huge.mcpjc")
        FileManager.default.createFile(atPath: f.path, contents: nil)
        let h = try FileHandle(forWritingTo: f)
        try h.truncate(atOffset: UInt64(InputLimits.maxProjectBytes) + 10)    // 疎ファイル
        try h.close()
        XCTAssertThrowsError(try Project.load(from: f))
        let dirAsFile = tmp
        XCTAssertThrowsError(try Project.load(from: dirAsFile!))
    }

    // 復元

    func testRecoveryFileNames() {
        XCTAssertTrue(AutosaveRecovery.isSafeFileName("3F2A1C9E-4B7D-4E1F-8A55-0123456789AB.mcrecover"))
        for bad in ["../x.mcrecover", "a/b.mcrecover", ".mcrecover", ".hidden.mcrecover", "a b.mcrecover", "x.mcrecover.bak", "é.mcrecover",
                    String(repeating: "a", count: 65) + ".mcrecover", "a\u{0}.mcrecover"] {
            XCTAssertFalse(AutosaveRecovery.isSafeFileName(bad), bad)
        }
        XCTAssertNil(AutosaveRecovery.safeURL(sessionID: "../../evil", in: tmp))
        XCTAssertNotNil(AutosaveRecovery.safeURL(sessionID: UUID().uuidString, in: tmp))
    }

    func testRecoveryWriteStaysInsideFolderAndRefusesLinks() throws {
        let dir = tmp.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let e = AutosaveRecovery.Entry(name: "n", originalPath: nil, savedAt: Date(), project: try Project.new().encoded())
        XCTAssertFalse(AutosaveRecovery.write(e, sessionID: "../escape", in: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("escape.mcrecover").path))
        let id = UUID().uuidString
        XCTAssertTrue(AutosaveRecovery.write(e, sessionID: id, in: dir))
        XCTAssertEqual(AutosaveRecovery.list(in: dir).count, 1)
        // 写しの場所に、外のファイルへのリンクが置かれていたら書かない
        let target = try makeFile("victim.txt", "大事", mode: 0o644)
        let id2 = UUID().uuidString
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(AutosaveRecovery.fileName(sessionID: id2)), withDestinationURL: target)
        XCTAssertFalse(AutosaveRecovery.write(e, sessionID: id2, in: dir))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "大事")
        // 一覧にもリンクは出ない。リンク先は消えない
        XCTAssertEqual(AutosaveRecovery.list(in: dir).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testRecoveryLoadRejectsOversizeAndBadContent() throws {
        let dir = tmp.appendingPathComponent("Recovery2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let huge = dir.appendingPathComponent("huge.mcrecover")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let h = try FileHandle(forWritingTo: huge)
        try h.truncate(atOffset: UInt64(AutosaveRecovery.maxFileBytes) + 1)
        try h.close()
        XCTAssertNil(AutosaveRecovery.load(huge))
        // 中の project が深い入れ子・読めないものは出さない
        let evil = AutosaveRecovery.Entry(name: "n", originalPath: "/x", savedAt: Date(), project: Data(String(repeating: "[", count: 100_000).utf8))
        try AutosaveRecovery.encode(evil).write(to: dir.appendingPathComponent("evil.mcrecover"))
        XCTAssertTrue(AutosaveRecovery.list(in: dir).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: huge.path), "壊れた通常ファイルは捨てる")
    }

    func testRecoveryFuzzDoesNotCrash() throws {
        let good = try AutosaveRecovery.encode(AutosaveRecovery.Entry(name: "n", originalPath: "/a/b.mcpjc", savedAt: Date(), project: try Project.new().encoded()))
        var rng = Rng(s: 7)
        for _ in 0..<300 {
            var m = [UInt8](good)
            for _ in 0..<Int.random(in: 1...8, using: &rng) { m[Int.random(in: 0..<m.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            if Bool.random(using: &rng) { m = Array(m.prefix(Int.random(in: 0...m.count, using: &rng))) }
            let f = tmp.appendingPathComponent("fz-\(UUID().uuidString).mcrecover")
            try Data(m).write(to: f)
            _ = AutosaveRecovery.load(f)
            try? FileManager.default.removeItem(at: f)
        }
    }

    // 字幕

    func testSubtitleSizeCapAndTimeClamp() throws {
        let cue = "1\n00:00:01,000 --> 00:00:02,000\nあ\n\n"
        let big = String(repeating: cue, count: InputLimits.maxSubtitleBytes / cue.utf8.count + 100)
        let t0 = Date()
        let cues = SubtitleFile.parse(big)
        XCTAssertLessThanOrEqual(cues.count, SubtitleFile.maxCues)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 30)
        let f = tmp.appendingPathComponent("big.srt")
        try Data(big.utf8).write(to: f)
        XCTAssertThrowsError(try SubtitleFile.read(f)) { XCTAssertTrue($0 is InputLimits.Failure) }
        let t = SubtitleFile.parse("1\n99999999999999999999:00:00,000 --> 99999999999999999999:00:01,000\nx\n")
        XCTAssertTrue(t.allSatisfy { $0.start.isFinite && $0.end <= InputLimits.maxSeconds })
        let ok = tmp.appendingPathComponent("ok.srt")
        try Data(cue.utf8).write(to: ok)
        XCTAssertEqual(try SubtitleFile.read(ok)?.count, 1)
    }

    func testSubtitleFuzzDoesNotCrashOrHang() {
        let good = "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.500 align:start\n<i>こんにちは</i><rt>x</rt>\n\n2\n00:00:03,000 --> 00:00:04,000\n{\\an8}あ\n"
        var rng = Rng(s: 11)
        let t0 = Date()
        for _ in 0..<500 {
            var b = [UInt8](good.utf8)
            for _ in 0..<Int.random(in: 1...10, using: &rng) { b[Int.random(in: 0..<b.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            let s = String(decoding: b, as: UTF8.self)
            for c in SubtitleFile.parse(s) { XCTAssertTrue(c.start.isFinite && c.end.isFinite) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 30)
    }

    // フォント

    func testFontImportRejectsOtherTypesAndHugeFiles() throws {
        let txt = try makeFile("evil.txt", "x", mode: 0o644)
        XCTAssertThrowsError(try FontLibrary.add(txt, to: tmp.appendingPathComponent("Fonts")))
        let exe = try makeFile("evil.ttf.sh", "#!/bin/sh\n", mode: 0o755)
        XCTAssertThrowsError(try FontLibrary.add(exe, to: tmp.appendingPathComponent("Fonts")))
        let huge = tmp.appendingPathComponent("huge.ttf")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let h = try FileHandle(forWritingTo: huge)
        try h.truncate(atOffset: UInt64(InputLimits.maxFontBytes) + 1)
        try h.close()
        XCTAssertThrowsError(try FontLibrary.familyNames(of: huge))
        XCTAssertThrowsError(try FontLibrary.add(huge, to: tmp.appendingPathComponent("Fonts")))
        let junk = try makeFile("junk.otf", "これはフォントではない", mode: 0o644)
        XCTAssertThrowsError(try FontLibrary.add(junk, to: tmp.appendingPathComponent("Fonts")))
        let linkTarget = try makeFile("real.txt", "x", mode: 0o644)
        let link = tmp.appendingPathComponent("l.ttf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linkTarget)
        XCTAssertThrowsError(try FontLibrary.familyNames(of: link)) // 通常のファイルではない(リンク先は txt だが読めない)
    }

    // 素材の探し直し・パッケージ

    func testRelativeMediaPathsStayInsideProjectFolder() throws {
        let dir = tmp.appendingPathComponent("Pkg")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("media"), withIntermediateDirectories: true)
        XCTAssertEqual(MediaPaths.contained(relative: "media/a.mp4", in: dir.path), dir.path + "/media/a.mp4")
        for bad in ["../secret.mp4", "media/../../secret", "/etc/passwd", "", "a\u{0}b", "./..", ".."] {
            XCTAssertNil(MediaPaths.contained(relative: bad, in: dir.path), bad)
        }
        // フォルダの中のシンボリックリンクで外へ抜けるものも断る
        let outside = tmp.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertNil(MediaPaths.contained(relative: "escape/x.mp4", in: dir.path))
        // 探し直しの目印(hint)に「..」があっても、外のファイルは選ばない
        let hint = MediaHint(relative: "../Outside/x.mp4", size: nil)
        let r = MissingMedia.findReplacement(for: "/gone/x.mp4", hint: hint, candidates: [:], projectDir: dir.path, exists: { _ in true })
        XCTAssertNil(r)
        let r2 = MissingMedia.findReplacement(for: "../Outside/x.mp4", hint: nil, candidates: [:], projectDir: dir.path, exists: { _ in true })
        XCTAssertNil(r2)
    }

    // PSD

    func psdHeader(width: Int, height: Int, channels: Int, depth: Int) -> [UInt8] {
        var b = Array("8BPS".utf8)
        b += PSDBuilder.be16(1) + [UInt8](repeating: 0, count: 6) + PSDBuilder.be16(channels)
        b += PSDBuilder.be32(height) + PSDBuilder.be32(width) + PSDBuilder.be16(depth) + PSDBuilder.be16(3)
        b += PSDBuilder.be32(0) + PSDBuilder.be32(0) + PSDBuilder.be32(0)    // カラーモード・リソース・レイヤー情報
        return b
    }

    func testPSDZipBombIsRefusedWithoutHugeAllocation() {
        // 30000×4000 × 56 チャンネル × 16 ビット ≒ 13 GB の展開を要求する、小さなファイル
        var b = psdHeader(width: 30000, height: 4000, channels: 56, depth: 16)
        b += PSDBuilder.be16(2) + [0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]
        let t0 = Date()
        XCTAssertThrowsError(try PSDParser.parse(Data(b)))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        XCTAssertThrowsError(try PSDParser.inflate([0x78, 0x9c, 0, 0, 0], expected: PSDParser.maxInflateBytes + 1))
    }

    func testPSDDimensionAndLayerLimits() throws {
        XCTAssertThrowsError(try PSDParser.parse(Data(psdHeader(width: 40000, height: 10, channels: 3, depth: 8))))
        XCTAssertThrowsError(try PSDParser.parse(Data(psdHeader(width: 30000, height: 30000, channels: 3, depth: 8))))
        XCTAssertThrowsError(try PSDParser.parse(Data(psdHeader(width: 10, height: 10, channels: 99, depth: 8))))
        XCTAssertGreaterThan(PSDParser.maxLayers, 0)
        // レイヤーの画素数の合計の上限(大きなレイヤーを多数並べる)
        var b = Array("8BPS".utf8)
        b += PSDBuilder.be16(1) + [UInt8](repeating: 0, count: 6) + PSDBuilder.be16(3) + PSDBuilder.be32(1000) + PSDBuilder.be32(1000) + PSDBuilder.be16(8) + PSDBuilder.be16(3)
        b += PSDBuilder.be32(0) + PSDBuilder.be32(0)
        var info: [UInt8] = PSDBuilder.be16(8)
        for _ in 0..<8 {
            info += PSDBuilder.be32(0) + PSDBuilder.be32(0) + PSDBuilder.be32(10_000) + PSDBuilder.be32(10_000)   // 1 億画素 × 8
            info += PSDBuilder.be16(0)
            info += Array("8BIM".utf8) + Array("norm".utf8) + [255, 0, 0, 0]
            let extra: [UInt8] = PSDBuilder.be32(0) + PSDBuilder.be32(0) + [0, 0, 0, 0]
            info += PSDBuilder.be32(extra.count) + extra
        }
        let layerInfo = PSDBuilder.be32(info.count) + info
        b += PSDBuilder.be32(layerInfo.count) + layerInfo
        b += PSDBuilder.be16(0)
        let doc = try? PSDParser.parse(Data(b))
        XCTAssertTrue(doc == nil || doc?.layerError != nil, "画素数の合計の上限で止まる")
    }

    func testPSDFuzzDoesNotCrashOrHang() throws {
        var builder = PSDBuilder(width: 8, height: 6)
        builder.layers = [
            .init(name: "背景", rect: (0, 0, 6, 8), rgba: Array(repeating: [255, 0, 0, 255], count: 48)),
            .init(name: "緑", rect: (1, 2, 3, 6), rgba: Array(repeating: [0, 255, 0, 255], count: 8), rle: true),
            .init(name: "zip", rect: (0, 0, 2, 2), rgba: Array(repeating: [1, 2, 3, 255], count: 4), zipKind: 3),
        ]
        let good = [UInt8](builder.build())
        XCTAssertNoThrow(try PSDParser.parse(Data(good)))
        var rng = Rng(s: 42)
        let t0 = Date()
        for i in 0..<1500 {
            var m = good
            let n = Int.random(in: 1...12, using: &rng)
            for _ in 0..<n {
                let pos = Int.random(in: 0..<m.count, using: &rng)
                // ときどき 0xFF の塊(巨大な長さ・個数)を入れる
                if Bool.random(using: &rng), pos + 4 <= m.count { for k in 0..<4 { m[pos + k] = 0xFF } } else { m[pos] = UInt8.random(in: 0...255, using: &rng) }
            }
            if i % 7 == 0 { m = Array(m.prefix(Int.random(in: 0...m.count, using: &rng))) }
            _ = try? PSDParser.parse(Data(m))
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 60)
    }

    func testProjectFuzzRandomBytesDoesNotCrashOrHang() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rich", withExtension: "ymproj", subdirectory: "Fixtures"))
        let good = [UInt8](try Data(contentsOf: url))
        var rng = Rng(s: 99)
        let t0 = Date()
        for _ in 0..<400 {
            var m = good
            for _ in 0..<Int.random(in: 1...10, using: &rng) { m[Int.random(in: 0..<m.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
            if Bool.random(using: &rng) { m = Array(m.prefix(Int.random(in: 0...m.count, using: &rng))) }
            if let p = try? Project.decode(from: Data(m)) {
                XCTAssertTrue(p.width >= 1 && p.width <= InputLimits.maxPixelSide && p.height >= 1 && p.height <= InputLimits.maxPixelSide)
                for c in p.allClips { XCTAssertTrue(c.start.isFinite && c.duration.isFinite && abs(c.start) <= InputLimits.maxSeconds && abs(c.duration) <= InputLimits.maxSeconds) }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 60)
    }
}
