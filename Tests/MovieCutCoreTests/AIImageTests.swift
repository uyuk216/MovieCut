import XCTest
@testable import MovieCutCore

/// AI 画像生成フック: 指定のローカルのコマンドが画像を書く。プロンプトは標準入力と環境変数で渡る。クラウドは呼ばない。
/// テストのコマンドは、画像をコピーするだけの無害な sh スクリプト。
final class AIImageTests: XCTestCase {
    private var dir: URL!
    private var png: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ai-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        png = dir.appendingPathComponent("source.png")
        try XCTUnwrap(QRCode.pngData(text: "ai-image-test")).write(to: png)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 中身の sh スクリプトを書いて、実行できる形にする。引数は `$1` = 出力先。
    private func script(_ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testWritesReadableImageAndPassesPromptByStdinAndEnv() async throws {
        // 標準入力とプロンプトの環境変数が一致したときだけ画像を書く(一致しなければ終了コード 4)
        let cmd = try script("ok.sh", "IN=$(cat)\n[ \"$IN\" = \"$MOVIECUT_PROMPT\" ] || exit 4\n[ \"$IN\" = \"夕焼けの海\" ] || exit 5\ncp '\(png.path)' \"$1\"")
        let out = dir.appendingPathComponent("out.png")
        let p = try CommandImageProvider(commandLine: cmd)
        try await p.generate(prompt: "  夕焼けの海 \n", outputURL: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertTrue(AIImageStore.isReadableImage(out))
    }

    func testCommandLineQuotingIsSplitWithoutShell() throws {
        let cmd = try script("quoted sp.sh", "cp '\(png.path)' \"$1\"")
        // 空白を含むパスは引用符で囲めば 1 つの実行ファイルになる(シェル展開はしない)
        XCTAssertNoThrow(try CommandImageProvider(commandLine: "'\(cmd)'"))
    }

    func testNoOutputFileThrows() async throws {
        let cmd = try script("silent.sh", "cat > /dev/null")
        let out = dir.appendingPathComponent("none.png")
        do {
            try await CommandImageProvider(commandLine: cmd).generate(prompt: "x", outputURL: out)
            XCTFail("出力が無ければ失敗する")
        } catch let e as AIImageError {
            XCTAssertEqual(e, .noOutput)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testNonImageOutputIsRemovedAndThrows() async throws {
        let cmd = try script("text.sh", "cat > /dev/null; echo hello > \"$1\"")
        let out = dir.appendingPathComponent("text.png")
        do {
            try await CommandImageProvider(commandLine: cmd).generate(prompt: "x", outputURL: out)
            XCTFail("画像でないファイルは失敗する")
        } catch let e as AIImageError {
            XCTAssertEqual(e, .notAnImage)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "読めないファイルは残さない")
    }

    func testFailingCommandReportsExitCode() async throws {
        let cmd = try script("fail.sh", "cat > /dev/null; echo oops >&2; exit 7")
        do {
            try await CommandImageProvider(commandLine: cmd).generate(prompt: "x", outputURL: dir.appendingPathComponent("f.png"))
            XCTFail("終了コードが 0 でなければ失敗する")
        } catch let e as AIError {
            guard case .nonZeroExit(let code, _) = e else { return XCTFail("別のエラー: \(e)") }
            XCTAssertEqual(code, 7)
        }
    }

    func testEmptyAndTooLongPromptsAreRefusedBeforeRunning() async throws {
        let cmd = try script("never.sh", "touch \"$1\"")
        let out = dir.appendingPathComponent("never.png")
        let p = try CommandImageProvider(commandLine: cmd)
        do { try await p.generate(prompt: "   ", outputURL: out); XCTFail() } catch { XCTAssertEqual(error as? AIImageError, .emptyPrompt) }
        let long = String(repeating: "あ", count: AIImageSettings.maxPromptLength + 1)
        do { try await p.generate(prompt: long, outputURL: out); XCTFail() } catch {
            XCTAssertEqual(error as? AIImageError, .promptTooLong(AIImageSettings.maxPromptLength + 1))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "拒んだときは実行しない")
    }

    func testMissingExecutableIsReportedWhenConfiguring() {
        XCTAssertThrowsError(try CommandImageProvider(commandLine: "/no/such/dir/tool-xyz")) { e in
            XCTAssertEqual(e as? AIError, .commandNotFound("/no/such/dir/tool-xyz"))
        }
        XCTAssertThrowsError(try CommandImageProvider(commandLine: "   ")) { e in
            XCTAssertEqual(e as? AIError, .emptyCommand)
        }
    }

    func testSettingsTrimTheCommandAndDefaultIsEmpty() {
        let suite = UserDefaults(suiteName: "ai-image-test-\(UUID().uuidString)")!
        XCTAssertEqual(AIImageSettings.command(suite), "")
        AIImageSettings.setCommand("  /usr/bin/true \n", suite)
        XCTAssertEqual(AIImageSettings.command(suite), "/usr/bin/true")
    }

    func testCancellationStopsTheCommand() async throws {
        let cmd = try script("slow.sh", "cat > /dev/null; exec sleep 30")
        let out = dir.appendingPathComponent("slow.png")
        let p = try CommandImageProvider(commandLine: cmd, timeout: 60)
        let t = Task { try await p.generate(prompt: "x", outputURL: out) }
        try await Task.sleep(nanoseconds: 300_000_000)
        t.cancel()
        let started = Date()
        do { try await t.value; XCTFail("キャンセルされたら失敗する") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "待たずに止まる")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
}
