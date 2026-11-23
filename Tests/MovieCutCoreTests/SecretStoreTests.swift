import XCTest
@testable import MovieCutCore

final class SecretStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "secretstore-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testSaveGoesToSecretStoreNotDefaults() {
        let d = defaults(), store = SecretStore(backend: InMemorySecretBackend())
        var s = VideoGenerationSettings(); s.apiKey = "k-video"
        s.save(to: d, secrets: store)
        XCTAssertNil(d.string(forKey: "videogen.apiKey"))
        XCTAssertEqual(store.get("videogen.apiKey"), "k-video")
        XCTAssertEqual(VideoGenerationSettings.load(from: d, secrets: store).apiKey, "k-video")
    }

    func testMigratesPlaintextForAllFour() {
        let d = defaults(), store = SecretStore(backend: InMemorySecretBackend())
        for k in ["videogen.apiKey", "audiogen.apiKey", "imagegen.apiKey", "textgen.apiKey"] { d.set("old-" + k, forKey: k) }
        XCTAssertEqual(VideoGenerationSettings.load(from: d, secrets: store).apiKey, "old-videogen.apiKey")
        XCTAssertEqual(AudioGenerationSettings.load(from: d, secrets: store).apiKey, "old-audiogen.apiKey")
        XCTAssertEqual(ImageGenerationSettings.load(from: d, secrets: store).apiKey, "old-imagegen.apiKey")
        XCTAssertEqual(TextGenerationSettings.load(from: d, secrets: store).apiKey, "old-textgen.apiKey")
        for k in ["videogen.apiKey", "audiogen.apiKey", "imagegen.apiKey", "textgen.apiKey"] {
            XCTAssertNil(d.object(forKey: k), k)
            XCTAssertEqual(store.get(k), "old-" + k)
        }
    }

    func testMigrationKeepsExistingSecretAndClearingRemoves() {
        let d = defaults(), store = SecretStore(backend: InMemorySecretBackend())
        store.set("new", account: "textgen.apiKey")
        d.set("stale", forKey: "textgen.apiKey")
        XCTAssertEqual(TextGenerationSettings.load(from: d, secrets: store).apiKey, "new")
        XCTAssertNil(d.object(forKey: "textgen.apiKey"))
        var s = TextGenerationSettings(); s.apiKey = ""
        s.save(to: d, secrets: store)
        XCTAssertEqual(store.get("textgen.apiKey"), "")
    }
}


/// 移行の書き込みが失敗する保存先では、平文の控えを消さない(キーを失わない)。
final class SecretStoreMigrationFailureTests: XCTestCase {
    /// 書き込みが常に失敗する保存先(キーチェーンがロックされている状態の再現)。
    final class FailingBackend: SecretBackend {
        func read(account: String) -> String? { nil }
        func write(_ value: String, account: String) {}
        func delete(account: String) {}
    }

    func testFailedMigrationKeepsPlaintextCopy() {
        let name = "secretstore-fail-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        d.set("my-key", forKey: "textgen.apiKey")
        let store = SecretStore(backend: FailingBackend())
        _ = store.load(account: "textgen.apiKey", migratingFrom: d)
        XCTAssertEqual(d.string(forKey: "textgen.apiKey"), "my-key", "移行に失敗したら平文の控えを消さない")
    }
}
