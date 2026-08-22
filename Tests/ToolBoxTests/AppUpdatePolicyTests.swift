import Foundation
import XCTest
@testable import ToolBoxCore

final class AppUpdatePolicyTests: XCTestCase {
    func testStableChannelIgnoresDraftsBetasAndNonAppAssets() {
        let releases = [
            release(version: "3.0.0", day: 4, draft: true),
            release(version: "Beta260816", day: 3, prerelease: true),
            release(version: "2.0.0", day: 2, hasAppArchive: false),
            release(version: "1.2.0", day: 1),
        ]

        XCTAssertEqual(
            AppUpdatePolicy.latestUpdate(
                in: releases,
                channel: .stable,
                currentVersion: "1.1.0"
            )?.version,
            "1.2.0"
        )
    }

    func testBetaChannelUsesMostRecentlyPublishedStableOrPrerelease() {
        let releases = [
            release(version: "1.2.0", day: 2),
            release(version: "Beta260816", day: 3, prerelease: true),
        ]

        XCTAssertEqual(
            AppUpdatePolicy.latestUpdate(
                in: releases,
                channel: .beta,
                currentVersion: "1.1.0"
            )?.version,
            "Beta260816"
        )
    }

    func testKnownCurrentReleasePreventsDowngrade() {
        let releases = [
            release(version: "1.2.0", day: 2),
            release(version: "Beta260816", day: 3, prerelease: true),
        ]

        XCTAssertNil(AppUpdatePolicy.latestUpdate(
            in: releases,
            channel: .beta,
            currentVersion: "Beta260816"
        ))
    }

    func testStableChannelDoesNotReplaceBetaWithAnOlderStable() {
        XCTAssertNil(AppUpdatePolicy.latestUpdate(
            in: [release(version: "1.2.0", day: 2)],
            channel: .stable,
            currentVersion: "Beta260816"
        ))
    }

    func testNumericVersionsCompareByComponents() {
        let latest = release(version: "1.10.0", day: 2)

        XCTAssertNotNil(AppUpdatePolicy.latestUpdate(
            in: [latest],
            channel: .stable,
            currentVersion: "1.9.9"
        ))
        XCTAssertNil(AppUpdatePolicy.latestUpdate(
            in: [latest],
            channel: .stable,
            currentVersion: "2.0.0"
        ))
    }

    func testDevelopmentVersionDetectsButDoesNotAffectSelection() {
        let latest = release(version: "1.2.0", day: 1)

        XCTAssertTrue(AppUpdatePolicy.isDevelopmentVersion("DEV0.0.0"))
        XCTAssertFalse(AppUpdatePolicy.isDevelopmentVersion("1.0.0"))
        XCTAssertEqual(
            AppUpdatePolicy.latestUpdate(
                in: [latest],
                channel: .stable,
                currentVersion: "DEV0.0.0"
            )?.version,
            "1.2.0"
        )
    }

    func testRejectsUnsafeVersionFromArchiveName() {
        let unsafe = AppRelease(
            tagName: "unsafe",
            title: "unsafe",
            isDraft: false,
            isPrerelease: false,
            publishedAt: Date(),
            assets: [AppUpdateAsset(
                name: "ToolBox-../escape.app.zip",
                byteCount: 100,
                downloadURL: URL(string: "https://github.com/example/update")!
            )]
        )

        XCTAssertNil(unsafe.appArchive)
        XCTAssertNil(unsafe.version)
    }

    func testDecodesGitHubAssetDigest() throws {
        let json = """
        {
          "tag_name": "v1.2.0",
          "name": "ToolBox 1.2.0",
          "draft": false,
          "prerelease": false,
          "published_at": "2026-08-16T00:00:00Z",
          "assets": [{
            "name": "ToolBox-1.2.0.app.zip",
            "size": 123,
            "browser_download_url": "https://github.com/example/update",
            "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          }]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let release = try decoder.decode(AppRelease.self, from: Data(json.utf8))

        XCTAssertEqual(
            release.appArchive?.digest,
            "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
    }

    private func release(
        version: String,
        day: Int,
        draft: Bool = false,
        prerelease: Bool = false,
        hasAppArchive: Bool = true
    ) -> AppRelease {
        let asset = AppUpdateAsset(
            name: hasAppArchive ? "ToolBox-\(version).app.zip" : "ToolBox-\(version).dmg",
            byteCount: 100,
            downloadURL: URL(string: "https://github.com/example/update")!
        )
        return AppRelease(
            tagName: prerelease ? "beta-260816" : "v\(version)",
            title: "ToolBox \(version)",
            isDraft: draft,
            isPrerelease: prerelease,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(day * 86_400)),
            assets: [asset]
        )
    }
}
