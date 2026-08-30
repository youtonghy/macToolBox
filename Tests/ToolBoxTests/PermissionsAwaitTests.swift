import XCTest
@testable import ToolBoxCore

final class PermissionsAwaitTests: XCTestCase {
    func testCancelledWaitNeverCompletes() {
        let exp = expectation(description: "cancelled wait must not complete")
        exp.isInverted = true

        let permissionWait = Permissions.awaitEventPosting(timeout: 30) { _ in
            exp.fulfill()
        }
        permissionWait.cancel()

        wait(for: [exp], timeout: 2)
    }
}

@MainActor
final class ClipboardPasteServiceTests: XCTestCase {
    func testWriteDeclaresCapturedImageType() {
        let service = ClipboardPasteService()
        let pasteboard = NSPasteboard.withUniqueName()

        let tiffBytes = Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0])
        let item = ClipboardItem(
            contentHash: "tiff",
            types: [.tiff],
            textContent: nil,
            imageData: tiffBytes,
            imageType: .tiff
        )

        // The returned snapshot must match the pasteboard state after writing.
        let changeCount = service.write(item, to: pasteboard)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.data(forType: .tiff), tiffBytes)
        // No false PNG declaration for TIFF bytes.
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testWriteTextItem() {
        let service = ClipboardPasteService()
        let pasteboard = NSPasteboard.withUniqueName()

        let item = ClipboardItem(
            contentHash: "text",
            types: [.string],
            textContent: "hello",
            imageData: nil
        )

        let changeCount = service.write(item, to: pasteboard)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")
    }
}
