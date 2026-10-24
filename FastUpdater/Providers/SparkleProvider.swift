import Foundation

/// Checks apps that embed Sparkle by reading their appcast feeds.
struct SparkleProvider: Sendable {
    struct Result: Sendable {
        /// Paths of apps whose feed was fetched and parsed, whether or not it had an update.
        var checkedAppPaths: Set<String> = []
        var updates: [AvailableUpdate] = []
    }

    func checkForUpdates(apps: [InstalledApp]) async -> Result {
        // Each task yields nil when the feed couldn't be read, or .some(update?) when it could.
        await withTaskGroup(of: (String, AvailableUpdate??).self) { group in
            for app in apps where app.sparkleFeedURL != nil {
                group.addTask {
                    // Not `try?`: it would flatten a failure into "checked, no update".
                    do { return (app.url.path, .some(try await check(app))) } catch { return (app.url.path, nil) }
                }
            }
            var result = Result()
            for await (path, outcome) in group {
                guard let outcome else { continue }
                result.checkedAppPaths.insert(path)
                if let update = outcome { result.updates.append(update) }
            }
            return result
        }
    }

    private func check(_ app: InstalledApp) async throws -> AvailableUpdate? {
        guard let feedURL = app.sparkleFeedURL,
              let current = app.buildVersion ?? app.shortVersion else { return nil }

        var request = URLRequest(url: feedURL, timeoutInterval: 20)
        request.setValue("FastUpdater/0.1 Sparkle/2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        guard let release = AppcastParser.bestRelease(in: try AppcastParser.parse(data)),
              let version = release.version,
              VersionComparator.isNewer(version, than: current) else { return nil }

        return AvailableUpdate(
            app: app,
            newVersion: release.displayVersion,
            source: .sparkle(release),
            releaseNotes: release.descriptionHTML,
            releaseNotesURL: release.releaseNotesURL
        )
    }
}
