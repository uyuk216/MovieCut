import XCTest
@testable import MovieCutCore

final class MemoryBudgetTests: XCTestCase {
    private let gib = MemoryBudget.gib

    // MARK: - 予算表(generic = 例外なし)

    func testTableValuesGeneric() {
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 32 * gib, platform: .generic), 16 * gib)
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 24 * gib, platform: .generic), 12 * gib)
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 16 * gib, platform: .generic), 6 * gib)
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 8 * gib, platform: .generic), 2 * gib)
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 4 * gib, platform: .generic), gib / 2)
    }

    func testBetweenTiersUsesLowerTier() {
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 20 * gib, platform: .generic), 6 * gib, "20GBは16GB階級")
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 31 * gib, platform: .generic), 12 * gib)
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 12 * gib, platform: .generic), 2 * gib)
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 5 * gib, platform: .generic), gib / 2)
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 64 * gib, platform: .generic), 16 * gib, "表より上は最上階級")
    }

    func testBelowSmallestTierUsesSmallest() {
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 2 * gib, platform: .generic), gib / 2)
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 1 * gib, platform: .generic), gib / 2)
    }

    // MARK: - プラットフォーム例外

    func testMacUnlimitedAt24GBAndAbove() {
        XCTAssertNil(MemoryBudget.limitBytes(totalRAMBytes: 24 * gib, platform: .mac))
        XCTAssertNil(MemoryBudget.limitBytes(totalRAMBytes: 32 * gib, platform: .mac))
        XCTAssertNil(MemoryBudget.limitBytes(totalRAMBytes: 64 * gib, platform: .mac))
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 16 * gib, platform: .mac), 6 * gib)
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 23 * gib, platform: .mac), 6 * gib)
    }

    func testWindowsUnlimitedAt32GBAndAbove() {
        XCTAssertNil(MemoryBudget.limitBytes(totalRAMBytes: 32 * gib, platform: .windows))
        XCTAssertNil(MemoryBudget.limitBytes(totalRAMBytes: 64 * gib, platform: .windows))
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 24 * gib, platform: .windows), 12 * gib, "Windowsは24GBでは例外にならない")
        XCTAssertEqual(MemoryBudget.limitBytes(totalRAMBytes: 31 * gib, platform: .windows), 12 * gib)
    }
}

final class CacheBudgetManagerTests: XCTestCase {
    func testLRUEvictionOrder() {
        let m = CacheBudgetManager(limitBytes: 300)
        var evicted: [String] = []
        m.register(key: "a", cost: 100) { evicted.append("a") }
        m.register(key: "b", cost: 100) { evicted.append("b") }
        m.register(key: "c", cost: 100) { evicted.append("c") }
        XCTAssertEqual(m.totalBytes, 300)
        XCTAssertTrue(evicted.isEmpty)
        // d を足すと最も古い a が落ちる
        let dropped = m.register(key: "d", cost: 100) { evicted.append("d") }
        XCTAssertEqual(dropped, ["a"])
        XCTAssertEqual(evicted, ["a"])
        XCTAssertEqual(m.totalBytes, 300)
        XCTAssertFalse(m.contains("a"))
        XCTAssertEqual(m.keysInLRUOrder, ["b", "c", "d"])
    }

    func testTouchMakesEntryMostRecent() {
        let m = CacheBudgetManager(limitBytes: 200)
        var evicted: [String] = []
        m.register(key: "a", cost: 100) { evicted.append("a") }
        m.register(key: "b", cost: 100) { evicted.append("b") }
        m.touch("a")
        m.register(key: "c", cost: 100) { evicted.append("c") }
        XCTAssertEqual(evicted, ["b"], "触れた a ではなく b が落ちる")
        XCTAssertEqual(m.keysInLRUOrder, ["a", "c"])
    }

    func testNeverExceedsLimitEvenWithOversizedEntry() {
        let m = CacheBudgetManager(limitBytes: 100)
        var evicted: [String] = []
        m.register(key: "big", cost: 500) { evicted.append("big") }
        XCTAssertLessThanOrEqual(m.totalBytes, 100)
        XCTAssertEqual(m.count, 0)
        XCTAssertEqual(evicted, ["big"])
    }

    func testMultipleEvictionsToFit() {
        let m = CacheBudgetManager(limitBytes: 250)
        for k in ["a", "b", "c"] { m.register(key: k, cost: 100) {} }
        // この時点で a が落ちて 200 になっているはず
        XCTAssertEqual(m.totalBytes, 200)
        m.register(key: "d", cost: 200) {}
        XCTAssertLessThanOrEqual(m.totalBytes, 250)
        XCTAssertEqual(m.keysInLRUOrder, ["d"])
    }

    func testUnlimitedNeverEvicts() {
        let m = CacheBudgetManager(limitBytes: nil)
        var evicted = 0
        for i in 0..<50 { m.register(key: "k\(i)", cost: 1_000_000) { evicted += 1 } }
        XCTAssertEqual(evicted, 0)
        XCTAssertEqual(m.count, 50)
        XCTAssertEqual(m.totalBytes, 50_000_000)
    }

    func testReplaceSameKeyDoesNotEvictOldAndUpdatesCost() {
        let m = CacheBudgetManager(limitBytes: 300)
        var oldEvicted = false
        m.register(key: "a", cost: 100) { oldEvicted = true }
        m.register(key: "a", cost: 150) {}
        XCTAssertFalse(oldEvicted)
        XCTAssertEqual(m.totalBytes, 150)
        XCTAssertEqual(m.count, 1)
    }

    func testPurgeAllReleasesEverything() {
        let m = CacheBudgetManager(limitBytes: 10_000)
        var evicted: [String] = []
        m.register(key: "a", cost: 10) { evicted.append("a") }
        m.register(key: "b", cost: 20) { evicted.append("b") }
        m.purgeAll()
        XCTAssertEqual(m.count, 0)
        XCTAssertEqual(m.totalBytes, 0)
        XCTAssertEqual(evicted, ["a", "b"])
        // 二度目は何も起きない
        m.purgeAll()
        XCTAssertEqual(evicted, ["a", "b"])
    }

    func testRemoveCallsEvictOnce() {
        let m = CacheBudgetManager(limitBytes: 10_000)
        var calls = 0
        m.register(key: "a", cost: 10) { calls += 1 }
        XCTAssertTrue(m.remove("a"))
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(m.remove("a"))
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentAccessStaysWithinLimit() {
        let m = CacheBudgetManager(limitBytes: 1_000)
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            m.register(key: "k\(i % 40)", cost: 100) {}
            _ = m.totalBytes
            m.touch("k\(i % 40)")
        }
        XCTAssertLessThanOrEqual(m.totalBytes, 1_000)
    }

    func testInitFromRAMBudget() {
        let mac = CacheBudgetManager(totalRAMBytes: 24 * MemoryBudget.gib, platform: .mac)
        XCTAssertTrue(mac.isUnlimited)
        let small = CacheBudgetManager(totalRAMBytes: 8 * MemoryBudget.gib, platform: .generic)
        XCTAssertEqual(small.limitBytes, 2 * MemoryBudget.gib)
    }
}

final class PreviewTierTests: XCTestCase {
    private let gib = MemoryBudget.gib

    func testUnlimitedIsFull() {
        XCTAssertEqual(PreviewTier.tier(forLimitBytes: nil), .full)
        XCTAssertEqual(PreviewTier.full.resolutionScale, 1.0)
        XCTAssertEqual(PreviewTier.full.fpsScale, 1.0)
    }

    func testMiddleIsQuarterResolutionSameFPS() {
        XCTAssertEqual(PreviewTier.tier(forLimitBytes: 12 * gib), .reduced)
        XCTAssertEqual(PreviewTier.tier(forLimitBytes: 2 * gib), .reduced)
        XCTAssertEqual(PreviewTier.reduced.resolutionScale, 0.5, "面積 1/4 = 縦横それぞれ 1/2")
        XCTAssertEqual(PreviewTier.reduced.fpsScale, 1.0)
        XCTAssertEqual(PreviewTier.reduced.effectiveFPS(base: 60), 60)
        let s = PreviewTier.reduced.effectiveSize(width: 1920, height: 1080)
        XCTAssertEqual(s.width, 960); XCTAssertEqual(s.height, 540)
        XCTAssertEqual(s.width * s.height, 1920 * 1080 / 4, "面積が 1/4")
    }

    func testLowIsSixteenthResolutionHalfFPS() {
        XCTAssertEqual(PreviewTier.tier(forLimitBytes: gib / 2), .minimal)
        XCTAssertEqual(PreviewTier.minimal.resolutionScale, 0.25, "面積 1/16 = 縦横それぞれ 1/4")
        XCTAssertEqual(PreviewTier.minimal.fpsScale, 0.5)
        XCTAssertEqual(PreviewTier.minimal.effectiveFPS(base: 60), 30)
        let s = PreviewTier.minimal.effectiveSize(width: 1920, height: 1080)
        XCTAssertEqual(s.width, 480); XCTAssertEqual(s.height, 270) // 1080*0.25=270
        XCTAssertEqual(s.width * s.height, 1920 * 1080 / 16, "面積が 1/16")
    }

    func testTierFromRAMAndPlatform() {
        XCTAssertEqual(PreviewTier.tier(totalRAMBytes: 24 * gib, platform: .mac), .full)
        XCTAssertEqual(PreviewTier.tier(totalRAMBytes: 32 * gib, platform: .windows), .full)
        XCTAssertEqual(PreviewTier.tier(totalRAMBytes: 16 * gib, platform: .generic), .reduced)
        XCTAssertEqual(PreviewTier.tier(totalRAMBytes: 4 * gib, platform: .generic), .minimal)
    }

    func testAppliesOnlyToVideoLayers() {
        XCTAssertTrue(PreviewTier.minimal.applies(to: .video))
        XCTAssertFalse(PreviewTier.minimal.applies(to: .image))
        XCTAssertFalse(PreviewTier.minimal.applies(to: .text))
        XCTAssertFalse(PreviewTier.minimal.applies(to: .audio))
        XCTAssertEqual(PreviewTier.minimal.effectiveTier(for: .image), .full)
        XCTAssertEqual(PreviewTier.minimal.effectiveTier(for: .video), .minimal)
    }
}
