import Foundation

/// League rosters for the Gamesheet's team dropdowns and player-name lookups. Downloaded from the
/// `rosters/rosters.json` this repo's Update rosters GitHub Action scrapes daily, and cached in
/// the app's support directory so it's still available at a rink with no signal.
@MainActor
final class RosterStore: ObservableObject {
    @Published private(set) var league: LeagueData?
    @Published private(set) var isRefreshing = false

    nonisolated static let defaultSourceURL = URL(string: "https://raw.githubusercontent.com/christianyipper/SoundBoard/main/rosters/rosters.json")!

    private let cacheURL: URL
    private let sourceURL: URL

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return decoder
    }

    /// Loads the cached rosters, then (when `refreshOnLaunch`) fetches the latest in the background.
    init(baseDirectory: URL, sourceURL: URL = defaultSourceURL, refreshOnLaunch: Bool = true) {
        cacheURL = baseDirectory.appendingPathComponent("rosters.json")
        self.sourceURL = sourceURL
        if let data = try? Data(contentsOf: cacheURL) {
            league = try? Self.decoder().decode(LeagueData.self, from: data)
        }
        if refreshOnLaunch {
            Task { await refresh() }
        }
    }

    /// Fetches the latest rosters; on any failure the current copy is kept.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
              let decoded = try? Self.decoder().decode(LeagueData.self, from: data) else { return }

        league = decoded
        try? data.write(to: cacheURL, options: .atomic)
    }
}
