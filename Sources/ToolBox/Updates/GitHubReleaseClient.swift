import Foundation

enum GitHubReleaseClientError: LocalizedError {
    case invalidResponse

    var errorDescription: String? { "GitHub 返回了无效的更新信息。" }
}

protocol AppReleaseFetching: Sendable {
    func fetchReleases() async throws -> [AppRelease]
}

struct GitHubReleaseClient: AppReleaseFetching, Sendable {
    private static let releasesURL = URL(
        string: "https://api.github.com/repos/youtonghy/macToolBox/releases?per_page=30"
    )!

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchReleases() async throws -> [AppRelease] {
        var request = URLRequest(url: Self.releasesURL)
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ToolBox-App-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else {
            throw GitHubReleaseClientError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AppRelease].self, from: data)
    }
}
