import XCTest
@testable import MovieCutCore

final class RecentProjectsTests: XCTestCase {
    func testTouchPutsNewestFirstAndDedupesStandardizedPath() {
        var r = RecentProjects()
        r.touch(path: "/a/x.mcpjc"); r.touch(path: "/a/y.mcpjc")
        r.touch(path: "/a/../a/./x.mcpjc")
        XCTAssertEqual(r.entries.map(\.path), ["/a/x.mcpjc", "/a/y.mcpjc"])
    }

    func testCapAt20DropsOldest() {
        var r = RecentProjects()
        for i in 0..<25 { r.touch(path: "/p/\(i).mcpjc") }
        XCTAssertEqual(r.entries.count, 20)
        XCTAssertEqual(r.entries.first?.path, "/p/24.mcpjc")
        XCTAssertEqual(r.entries.last?.path, "/p/5.mcpjc")
    }

    func testNameDropsExtensionAndTouchStoresDates() {
        var r = RecentProjects()
        let d = Date(timeIntervalSince1970: 1000), m = Date(timeIntervalSince1970: 500)
        r.touch(path: "/a/旅行.ymproj", modified: m, now: d)
        XCTAssertEqual(r.entries[0].name, "旅行")
        XCTAssertEqual(r.entries[0].lastOpened, d)
        XCTAssertEqual(r.entries[0].modified, m)
    }

    func testRemove() {
        var r = RecentProjects()
        r.touch(path: "/a/x.mcpjc"); r.touch(path: "/a/y.mcpjc")
        r.remove(path: "/a/../a/x.mcpjc")
        XCTAssertEqual(r.entries.map(\.path), ["/a/y.mcpjc"])
        r.removeAll()
        XCTAssertTrue(r.entries.isEmpty)
    }

    func testMissingDetectionWithInjectedClosure() {
        var r = RecentProjects()
        r.touch(path: "/a/x.mcpjc"); r.touch(path: "/a/y.mcpjc")
        let exists: (String) -> Bool = { $0 == "/a/y.mcpjc" }
        XCTAssertEqual(r.missingPaths(fileExists: exists), ["/a/x.mcpjc"])
        XCTAssertTrue(r.isMissing(r.entries[1], fileExists: exists))
        XCTAssertFalse(r.isMissing(r.entries[0], fileExists: exists))
        r.removeMissing(fileExists: exists)
        XCTAssertEqual(r.entries.map(\.path), ["/a/y.mcpjc"])
    }

    func testPersistenceRoundTripThroughStore() {
        let store = MemoryRecentProjectsStore()
        var r = RecentProjects()
        r.touch(path: "/a/x.mcpjc", modified: Date(timeIntervalSince1970: 5), now: Date(timeIntervalSince1970: 9))
        r.touch(path: "/a/y.mcpjc")
        r.save(to: store)
        XCTAssertEqual(RecentProjects.load(from: store), r)
    }

    func testLoadFromEmptyOrBrokenStoreIsEmpty() {
        XCTAssertTrue(RecentProjects.load(from: MemoryRecentProjectsStore()).entries.isEmpty)
        XCTAssertTrue(RecentProjects.load(from: MemoryRecentProjectsStore(data: Data("xx".utf8))).entries.isEmpty)
    }

    func testLoadDedupesAndCapsStoredList() {
        let list = (0..<30).map { RecentProject(path: "/p/\($0 % 25).mcpjc") }
        let store = MemoryRecentProjectsStore(data: try! JSONEncoder().encode(list))
        let r = RecentProjects.load(from: store)
        XCTAssertEqual(r.entries.count, 20)
        XCTAssertEqual(Set(r.entries.map(\.path)).count, 20)
    }

    func testUserDefaultsStoreAndWelcomeSettings() {
        let d = UserDefaults(suiteName: "RecentProjectsTests-\(UUID().uuidString)")!
        XCTAssertTrue(WelcomeSettings.showAtLaunch(d), "既定は表示")
        WelcomeSettings.setShowAtLaunch(false, d)
        XCTAssertFalse(WelcomeSettings.showAtLaunch(d))
        let store = UserDefaultsRecentProjectsStore(defaults: d)
        var r = RecentProjects(); r.touch(path: "/a/x.mcpjc"); r.save(to: store)
        XCTAssertEqual(RecentProjects.load(from: store).entries.map(\.path), ["/a/x.mcpjc"])
    }
}
