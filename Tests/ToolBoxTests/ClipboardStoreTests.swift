import XCTest
@testable import ToolBoxCore

final class ClipboardStoreTests: XCTestCase {
    var store: ClipboardStore!

    @MainActor
    override func setUp() {
        super.setUp()
        store = ClipboardStore(timeLimit: 3600, memoryLimit: 1024 * 1024)
    }

    @MainActor
    override func tearDown() {
        store = nil
        super.tearDown()
    }

    @MainActor
    func testAddItem() {
        let hash = "test_hash_1"
        store.addOrUpdate(hash: hash, text: "Hello", image: nil, types: [.string])

        XCTAssertEqual(store.itemCount, 1)
        XCTAssertEqual(store.items.first?.contentHash, hash)
        XCTAssertEqual(store.items.first?.textContent, "Hello")
    }

    @MainActor
    func testDeduplication() {
        let hash = "duplicate_hash"

        store.addOrUpdate(hash: hash, text: "First", image: nil, types: [.string])
        let firstTimestamp = store.items.first?.timestamp

        // Wait a bit to ensure different timestamp
        Thread.sleep(forTimeInterval: 0.01)

        store.addOrUpdate(hash: hash, text: "First", image: nil, types: [.string])

        // Should still have only 1 item
        XCTAssertEqual(store.itemCount, 1)

        // Timestamp should be updated
        XCTAssertNotEqual(store.items.first?.timestamp, firstTimestamp)
        XCTAssertGreaterThan(store.items.first?.timestamp ?? Date.distantPast, firstTimestamp ?? Date.distantFuture)
    }

    @MainActor
    func testTimeBasedCleanup() {
        // Set time limit to 1 hour
        store.setTimeLimit(3600)

        // Add old item
        store.addOrUpdate(hash: "old_hash", text: "Old content", image: nil, types: [.string])

        // Add recent item
        store.addOrUpdate(hash: "new_hash", text: "New content", image: nil, types: [.string])

        XCTAssertEqual(store.itemCount, 2)

        // Manually set very short time limit to expire the first item
        store.setTimeLimit(0.001)

        // Wait a tiny bit
        Thread.sleep(forTimeInterval: 0.01)

        // Trigger cleanup
        store.cleanupExpiredItems()

        // Old item should be removed
        XCTAssertLessThan(store.itemCount, 2)
    }

    @MainActor
    func testMemoryLimit() {
        // Create small memory limit
        store = ClipboardStore(timeLimit: 3600, memoryLimit: 200)

        // Add items until memory limit is hit
        for i in 0..<10 {
            let text = String(repeating: "x", count: 50)
            store.addOrUpdate(hash: "hash_\(i)", text: text, image: nil, types: [.string])
        }

        // Store should have evicted old items to stay under limit
        XCTAssertLessThanOrEqual(store.memoryUsage, 200)
        XCTAssertLessThan(store.itemCount, 10)
    }

    @MainActor
    func testClear() {
        store.addOrUpdate(hash: "h1", text: "Text 1", image: nil, types: [.string])
        store.addOrUpdate(hash: "h2", text: "Text 2", image: nil, types: [.string])

        XCTAssertEqual(store.itemCount, 2)

        store.clear()

        XCTAssertEqual(store.itemCount, 0)
        XCTAssertEqual(store.memoryUsage, 0)
    }

    @MainActor
    func testSetMemoryLimit() {
        // Add items
        for i in 0..<5 {
            let text = String(repeating: "x", count: 100)
            store.addOrUpdate(hash: "hash_\(i)", text: text, image: nil, types: [.string])
        }

        let initialCount = store.itemCount
        XCTAssertGreaterThan(initialCount, 0)

        // Reduce memory limit drastically
        store.setMemoryLimit(100)

        // Should evict items
        XCTAssertLessThan(store.itemCount, initialCount)
        XCTAssertLessThanOrEqual(store.memoryUsage, 100)
    }

    @MainActor
    func testItemOrdering() {
        store.addOrUpdate(hash: "h1", text: "First", image: nil, types: [.string])
        Thread.sleep(forTimeInterval: 0.01)
        store.addOrUpdate(hash: "h2", text: "Second", image: nil, types: [.string])
        Thread.sleep(forTimeInterval: 0.01)
        store.addOrUpdate(hash: "h3", text: "Third", image: nil, types: [.string])

        // Most recent should be first
        XCTAssertEqual(store.items[0].contentHash, "h3")
        XCTAssertEqual(store.items[1].contentHash, "h2")
        XCTAssertEqual(store.items[2].contentHash, "h1")
    }
}
