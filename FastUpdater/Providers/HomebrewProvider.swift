import Foundation

/// Checks apps installed as Homebrew casks.
struct HomebrewProvider: Sendable {
    struct Result: Sendable {
        /// Paths of installed apps that Homebrew manages, whether or not they're outdated.
        var managedAppPaths: Set<String> = []
        var updates: [AvailableUpdate] = []
    }

    static var brewPath: String? { Shell.findTool("brew") }

    func checkForUpdates(apps: [InstalledApp]) async throws -> Result {
        guard let brew = Self.brewPath else { return Result() }

        async let infoResult = Shell.runChecked(brew, ["info", "--cask", "--installed", "--json=v2"])
        async let outdatedResult = Shell.runChecked(brew, ["outdated", "--cask", "--greedy", "--json=v2"])
        let tokensByAppName = Self.appArtifacts(fromInfoJSON: try await infoResult.stdout)
        let outdated = Self.outdatedCasks(fromJSON: try await outdatedResult.stdout)

        var result = Result()
        for app in apps {
            guard let token = tokensByAppName[app.url.lastPathComponent] else { continue }
            result.managedAppPaths.insert(app.url.path)

            guard let latest = outdated[token] else { continue }
            // Cask versions often look like "1.2.3,4567"; the first part is the app version.
            let latestAppVersion = latest.split(separator: ",").first.map(String.init) ?? latest
            if latestAppVersion == "latest" { continue }
            // `--greedy` also lists self-updating apps by the version brew installed;
            // skip them if the app has already updated itself.
            if let installed = app.shortVersion,
               !VersionComparator.isNewer(latestAppVersion, than: installed) { continue }

            result.updates.append(AvailableUpdate(
                app: app,
                newVersion: latestAppVersion,
                source: .homebrew(token: token),
                releaseNotes: nil,
                releaseNotesURL: nil
            ))
        }
        return result
    }

    /// Maps "Foo.app" → cask token, from `brew info --cask --json=v2`.
    static func appArtifacts(fromInfoJSON json: String) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [:] }

        var map: [String: String] = [:]
        for cask in casks {
            guard let token = cask["token"] as? String,
                  let artifacts = cask["artifacts"] as? [[String: Any]] else { continue }
            for artifact in artifacts {
                guard let entries = artifact["app"] as? [Any] else { continue }
                // Entries are either "Source.app" or a {"target": "Name.app"} rename
                // that applies to the preceding source.
                var lastName: String?
                for entry in entries {
                    if let name = entry as? String {
                        lastName = (name as NSString).lastPathComponent
                        map[lastName!] = token
                    } else if let options = entry as? [String: Any],
                              let target = options["target"] as? String {
                        if let lastName { map.removeValue(forKey: lastName) }
                        map[(target as NSString).lastPathComponent] = token
                    }
                }
            }
        }
        return map
    }

    /// Maps cask token → latest version, from `brew outdated --cask --json=v2`.
    static func outdatedCasks(fromJSON json: String) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for cask in casks {
            if let name = cask["name"] as? String, let version = cask["current_version"] as? String {
                map[name] = version
            }
        }
        return map
    }
}
