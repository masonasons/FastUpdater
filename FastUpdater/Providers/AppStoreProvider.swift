import Foundation

/// Checks App Store apps against Apple's public lookup API: Mac apps by bundle ID, and
/// iPhone/iPad apps (which record their store item ID) by ID, in the store they came from.
struct AppStoreProvider: Sendable {
    private struct LookupResponse: Decodable {
        struct Item: Decodable {
            let bundleId: String
            let version: String
            let trackId: Int
            let releaseNotes: String?
            let trackViewUrl: URL?
        }
        let results: [Item]
    }

    var country = Locale.current.region?.identifier ?? "US"

    func checkForUpdates(apps: [InstalledApp]) async throws -> [AvailableUpdate] {
        let storeApps = apps.filter(\.isFromAppStore)
        guard !storeApps.isEmpty else { return [] }

        let macApps = storeApps.filter { !$0.isiOSApp }
        let iOSApps = storeApps.filter { $0.isiOSApp && $0.appStoreID != nil }

        // Mac apps: keyed by bundle ID.
        var macItems: [String: LookupResponse.Item] = [:]
        for chunk in Self.chunks(macApps) {
            let query = ("bundleId", chunk.map(\.bundleID).joined(separator: ","))
            for item in try await lookup(query, entity: "desktopSoftware", country: country) {
                macItems[item.bundleId] = item
            }
        }

        // iPhone/iPad apps: keyed by item ID, grouped by the store they were bought from.
        var iOSItems: [Int: LookupResponse.Item] = [:]
        for (storeCountry, group) in Dictionary(grouping: iOSApps, by: { $0.storeCountry ?? country }) {
            for chunk in Self.chunks(group) {
                let query = ("id", chunk.compactMap(\.appStoreID).map(String.init).joined(separator: ","))
                for item in try await lookup(query, entity: nil, country: storeCountry) {
                    iOSItems[item.trackId] = item
                }
            }
        }

        return storeApps.compactMap { app in
            let item = app.isiOSApp ? app.appStoreID.flatMap { iOSItems[$0] } : macItems[app.bundleID]
            guard let item,
                  let installed = app.shortVersion,
                  VersionComparator.isNewer(item.version, than: installed) else { return nil }
            return AvailableUpdate(
                app: app,
                newVersion: item.version,
                source: .appStore(trackID: item.trackId),
                releaseNotes: item.releaseNotes,
                releaseNotesURL: item.trackViewUrl
            )
        }
    }

    private static func chunks(_ apps: [InstalledApp]) -> [ArraySlice<InstalledApp>] {
        stride(from: 0, to: apps.count, by: 50).map { apps[$0..<min($0 + 50, apps.count)] }
    }

    private func lookup(_ query: (name: String, value: String), entity: String?, country: String) async throws -> [LookupResponse.Item] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: query.name, value: query.value),
            URLQueryItem(name: "country", value: country),
        ] + (entity.map { [URLQueryItem(name: "entity", value: $0)] } ?? [])
        let request = URLRequest(url: components.url!, timeoutInterval: 20)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(LookupResponse.self, from: data).results
    }
}
