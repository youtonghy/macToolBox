import Foundation
import CryptoKit
import Security

struct PendingAppUpdate: Codable, Equatable, Sendable {
    let version: String
    let stagedAppPath: String

    var stagedAppURL: URL { URL(fileURLWithPath: stagedAppPath, isDirectory: true) }
}

enum AppUpdateInstallError: LocalizedError {
    case missingArchive
    case invalidDownload
    case invalidApplication
    case invalidBundleIdentifier
    case invalidVersion
    case invalidSignature
    case signingCertificateMismatch
    case insufficientDiskSpace
    case installationLocationNotWritable
    case helperLaunchFailed

    var errorDescription: String? {
        switch self {
        case .missingArchive: return "该 Release 没有可用的应用更新包。"
        case .invalidDownload: return "下载的更新包不完整或来源无效。"
        case .invalidApplication: return "更新包中没有有效的 ToolBox 应用。"
        case .invalidBundleIdentifier: return "更新包的应用标识与当前应用不一致。"
        case .invalidVersion: return "更新包的版本与 GitHub Release 不一致。"
        case .invalidSignature: return "更新包的代码签名校验失败。"
        case .signingCertificateMismatch: return "更新包与当前应用不是由同一证书签名。"
        case .insufficientDiskSpace: return "可用磁盘空间不足，无法下载并解压更新。"
        case .installationLocationNotWritable: return "当前安装位置不可写，无法自动替换应用。"
        case .helperLaunchFailed: return "无法启动更新安装程序。"
        }
    }
}

private final class GitHubAssetRedirectPolicy: NSObject, URLSessionTaskDelegate {
    private static let exactHosts: Set<String> = [
        "github.com",
        "api.github.com",
        "objects.githubusercontent.com",
        "github-releases.githubusercontent.com",
    ]

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return exactHosts.contains(host) || host.hasSuffix(".githubusercontent.com")
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.isAllowed(request.url) ? request : nil)
    }
}

actor AppUpdateInstaller {
    private let fileManager: FileManager
    private let session: URLSession
    private let currentBundle: Bundle
    private let rootDirectory: URL
    private let pendingMetadataURL: URL

    init(
        fileManager: FileManager = .default,
        currentBundle: Bundle = .main,
        rootDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.currentBundle = currentBundle
        let base = rootDirectory ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("ToolBox/Updates", isDirectory: true)
        self.rootDirectory = base
        self.pendingMetadataURL = base.appendingPathComponent("pending.json")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.waitsForConnectivity = true
        self.session = URLSession(
            configuration: configuration,
            delegate: GitHubAssetRedirectPolicy(),
            delegateQueue: nil
        )
    }

    func restorePendingUpdate() throws -> PendingAppUpdate? {
        guard fileManager.fileExists(atPath: pendingMetadataURL.path) else { return nil }
        let pending = try JSONDecoder().decode(
            PendingAppUpdate.self,
            from: Data(contentsOf: pendingMetadataURL)
        )
        try validate(stagedApp: pending.stagedAppURL, expectedVersion: pending.version)
        return pending
    }

    func downloadAndStage(_ release: AppRelease) async throws -> PendingAppUpdate {
        guard let asset = release.appArchive, let version = release.version else {
            throw AppUpdateInstallError.missingArchive
        }
        guard asset.byteCount > 0,
              asset.byteCount <= 2_000_000_000,
              GitHubAssetRedirectPolicy.isAllowed(asset.downloadURL)
        else {
            throw AppUpdateInstallError.invalidDownload
        }

        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let capacity = try rootDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < asset.byteCount * 4 {
            throw AppUpdateInstallError.insufficientDiskSpace
        }
        let versionDirectory = rootDirectory.appendingPathComponent(version, isDirectory: true)
        if fileManager.fileExists(atPath: versionDirectory.path) {
            try fileManager.removeItem(at: versionDirectory)
        }
        try fileManager.createDirectory(
            at: versionDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let (temporaryURL, response) = try await session.download(from: asset.downloadURL)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  GitHubAssetRedirectPolicy.isAllowed(response.url)
            else {
                throw AppUpdateInstallError.invalidDownload
            }
            let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            guard Int64(values.fileSize ?? -1) == asset.byteCount else {
                throw AppUpdateInstallError.invalidDownload
            }
            try validateDigest(of: temporaryURL, expected: asset.digest)

            let archiveURL = versionDirectory.appendingPathComponent("update.app.zip")
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
            try run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, versionDirectory.path])
            try fileManager.removeItem(at: archiveURL)

            let stagedApp = versionDirectory.appendingPathComponent("ToolBox.app", isDirectory: true)
            try validate(stagedApp: stagedApp, expectedVersion: version)
            let pending = PendingAppUpdate(version: version, stagedAppPath: stagedApp.path)
            try JSONEncoder().encode(pending).write(to: pendingMetadataURL, options: .atomic)
            return pending
        } catch {
            try? fileManager.removeItem(at: versionDirectory)
            throw error
        }
    }

    func launchInstaller(for pending: PendingAppUpdate) throws {
        try validate(stagedApp: pending.stagedAppURL, expectedVersion: pending.version)
        let target = currentBundle.bundleURL
        guard fileManager.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw AppUpdateInstallError.installationLocationNotWritable
        }

        let helperURL = rootDirectory.appendingPathComponent("install-update.sh")
        let script = """
        #!/bin/sh
        set -eu
        pid="$1"
        staged="$2"
        target="$3"
        root="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        backup="${target}.update-backup-${pid}"
        if [ -e "$backup" ]; then exit 1; fi
        if ! mv "$target" "$backup"; then exit 1; fi
        if mv "$staged" "$target"; then
          /usr/bin/open "$target"
          rm -rf "$backup" "$root"
        else
          mv "$backup" "$target"
          exit 1
        fi
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            helperURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            pending.stagedAppURL.path,
            target.path,
            rootDirectory.path,
        ]
        do {
            try process.run()
        } catch {
            throw AppUpdateInstallError.helperLaunchFailed
        }
    }

    private func validate(stagedApp: URL, expectedVersion: String) throws {
        var isDirectory: ObjCBool = false
        let values = try stagedApp.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard fileManager.fileExists(atPath: stagedApp.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              values.isSymbolicLink != true,
              let stagedBundle = Bundle(url: stagedApp)
        else {
            throw AppUpdateInstallError.invalidApplication
        }
        guard stagedBundle.bundleIdentifier == currentBundle.bundleIdentifier else {
            throw AppUpdateInstallError.invalidBundleIdentifier
        }
        let stagedVersion = stagedBundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        guard stagedVersion == expectedVersion else {
            throw AppUpdateInstallError.invalidVersion
        }
        try validateSignature(of: stagedApp)
    }

    private func validateSignature(of stagedApp: URL) throws {
        guard let currentCode = staticCode(at: currentBundle.bundleURL),
              let stagedCode = staticCode(at: stagedApp)
        else {
            throw AppUpdateInstallError.invalidSignature
        }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        guard SecStaticCodeCheckValidity(stagedCode, flags, nil) == errSecSuccess else {
            throw AppUpdateInstallError.invalidSignature
        }
        let currentCertificate = signingCertificateData(for: currentCode)
        guard let currentCertificate,
              currentCertificate == signingCertificateData(for: stagedCode)
        else {
            throw AppUpdateInstallError.signingCertificateMismatch
        }
    }

    private func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private func signingCertificateData(for code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first
        else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }

    private func run(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateInstallError.invalidApplication
        }
    }

    private func validateDigest(of fileURL: URL, expected: String?) throws {
        guard let expected else { return }
        let prefix = "sha256:"
        guard expected.hasPrefix(prefix) else { throw AppUpdateInstallError.invalidDownload }
        let expectedHex = String(expected.dropFirst(prefix.count)).lowercased()
        guard expectedHex.count == 64, expectedHex.allSatisfy({ $0.isHexDigit }) else {
            throw AppUpdateInstallError.invalidDownload
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let actualHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHex == expectedHex else { throw AppUpdateInstallError.invalidDownload }
    }
}
