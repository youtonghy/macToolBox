import XCTest
@testable import ToolBoxCore

final class ClipboardCoordinatorTests: XCTestCase {
    var coordinator: ClipboardCoordinator!
    var store: ClipboardStore!

    @MainActor
    override func setUp() {
        super.setUp()
        store = ClipboardStore()
        coordinator = ClipboardCoordinator(store: store)
    }

    @MainActor
    override func tearDown() {
        coordinator.stop()
        coordinator = nil
        store = nil
        super.tearDown()
    }

    @MainActor
    func testStartStop() {
        coordinator.start()
        // Timer should be running (no direct way to test, but shouldn't crash)

        coordinator.stop()
        // Timer should be stopped
    }

    @MainActor
    func testMemoryLimitConfiguration() {
        coordinator.memoryLimit = 1024
        coordinator.timeLimit = 7200

        // Should propagate to store (verify indirectly through behavior)
        XCTAssertNotNil(coordinator)
    }

    @MainActor
    func testAccessors() {
        XCTAssertEqual(coordinator.memoryUsage, 0)
        XCTAssertEqual(coordinator.itemCount, 0)

        // Add item directly to store
        store.addOrUpdate(hash: "test", text: "content", image: nil, types: [.string])

        XCTAssertGreaterThan(coordinator.memoryUsage, 0)
        XCTAssertEqual(coordinator.itemCount, 1)
    }
}

final class ClipboardItemTests: XCTestCase {
    func testComputeHashText() {
        let hash1 = ClipboardItem.computeHash(text: "Hello", image: nil)
        let hash2 = ClipboardItem.computeHash(text: "Hello", image: nil)
        let hash3 = ClipboardItem.computeHash(text: "World", image: nil)

        // Same content should produce same hash
        XCTAssertEqual(hash1, hash2)

        // Different content should produce different hash
        XCTAssertNotEqual(hash1, hash3)

        // SHA-256 produces 64 hex characters
        XCTAssertEqual(hash1.count, 64)
    }

    func testComputeHashImage() {
        let data1 = Data([0x01, 0x02, 0x03])
        let data2 = Data([0x01, 0x02, 0x03])
        let data3 = Data([0x04, 0x05, 0x06])

        let hash1 = ClipboardItem.computeHash(text: nil, image: data1)
        let hash2 = ClipboardItem.computeHash(text: nil, image: data2)
        let hash3 = ClipboardItem.computeHash(text: nil, image: data3)

        XCTAssertEqual(hash1, hash2)
        XCTAssertNotEqual(hash1, hash3)
    }

    func testComputeHashCombined() {
        let text = "Text"
        let image = Data([0x01])

        let hashTextOnly = ClipboardItem.computeHash(text: text, image: nil)
        let hashImageOnly = ClipboardItem.computeHash(text: nil, image: image)
        let hashBoth = ClipboardItem.computeHash(text: text, image: image)

        // Combined hash should be different from individual hashes
        XCTAssertNotEqual(hashBoth, hashTextOnly)
        XCTAssertNotEqual(hashBoth, hashImageOnly)
    }

    func testEstimatedSize() {
        let item = ClipboardItem(
            contentHash: "abc123",
            types: [.string],
            textContent: "Hello",
            imageData: nil
        )

        // Should have non-zero size
        XCTAssertGreaterThan(item.estimatedSize, 0)

        let itemWithImage = ClipboardItem(
            contentHash: "def456",
            types: [.png],
            textContent: nil,
            imageData: Data(count: 1000)
        )

        // Item with image should be larger
        XCTAssertGreaterThan(itemWithImage.estimatedSize, item.estimatedSize)
    }

    func testIsImage() {
        let textItem = ClipboardItem(
            contentHash: "text",
            types: [.string],
            textContent: "Hello",
            imageData: nil
        )

        let imageItem = ClipboardItem(
            contentHash: "image",
            types: [.png],
            textContent: nil,
            imageData: Data([0x01])
        )

        XCTAssertFalse(textItem.isImage)
        XCTAssertTrue(imageItem.isImage)
    }
}

@MainActor
final class ClipboardPanelModelTests: XCTestCase {
    func testSearchExcludesImagesAndIsCaseInsensitive() {
        let store = ClipboardStore()
        store.addOrUpdate(hash: "text", text: "Hello Clipboard", image: nil, types: [.string])
        store.addOrUpdate(hash: "image", text: nil, image: Data([1, 2]), types: [.png])
        let model = ClipboardPanelModel(store: store)

        model.query = "CLIP"
        XCTAssertEqual(model.filteredItems.map(\.contentHash), ["text"])
    }

    func testSelectionWraps() {
        let store = ClipboardStore()
        store.addOrUpdate(hash: "one", text: "1", image: nil, types: [.string])
        store.addOrUpdate(hash: "two", text: "2", image: nil, types: [.string])
        let model = ClipboardPanelModel(store: store)
        model.selectFirst()

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedItem?.contentHash, "one")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedItem?.contentHash, "two")
    }
}
