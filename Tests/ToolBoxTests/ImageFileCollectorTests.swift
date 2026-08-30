import Foundation
import XCTest

@testable import ToolBoxCore

final class ImageFileCollectorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toolbox-collector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ relativePath: String, content: Data = Data("x".utf8)) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url)
    }

    func testCollectsFilesAndDirectoriesRecursively() throws {
        try touch("a.jpg")
        try touch("sub/b.png")
        try touch("sub/deep/c.webp")
        try touch("ignored.txt")
        try touch("sub/ignored.pdf")
        try touch(".hidden.jpg")

        let urls = try ImageFileCollector.collect(paths: [root.path], recursive: true)
        let names = Set(urls.map { $0.lastPathComponent })
        XCTAssertEqual(names, ["a.jpg", "b.png", "c.webp"])
    }

    func testTopLevelOnlyWhenNotRecursive() throws {
        try touch("a.jpg")
        try touch("sub/b.png")
        let urls = try ImageFileCollector.collect(paths: [root.path], recursive: false)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["a.jpg"])
    }

    func testDirectoryContentsSortedStably() throws {
        try touch("c.jpg")
        try touch("a.jpg")
        try touch("b.jpg")
        let urls = try ImageFileCollector.collect(paths: [root.path], recursive: true)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["a.jpg", "b.jpg", "c.jpg"])
    }

    func testTildeExpansion() throws {
        try touch("home.jpg")
        let urls = try ImageFileCollector.collect(paths: ["\(root.path)/../\(root.lastPathComponent)"], recursive: false)
        XCTAssertEqual(urls.count, 1)
    }

    func testMissingPathThrows() {
        XCTAssertThrowsError(try ImageFileCollector.collect(
            paths: ["/nonexistent/path/image.jpg"],
            recursive: true
        ))
    }

    func testSupportedExtensionsCoverAllPipelineFormats() {
        for format in ImageFormat.allCases {
            XCTAssertTrue(
                ImageFileCollector.supportedExtensions.contains(format.preferredFilenameExtension),
                "收集器缺少 \(format.rawValue) 的扩展名映射"
            )
        }
    }
}
