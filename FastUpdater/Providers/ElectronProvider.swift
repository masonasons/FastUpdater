import Foundation

/// Checks Electron apps that use electron-builder's auto-updater. They ship
/// `Contents/Resources/app-update.yml` naming a feed whose `latest-mac.yml`
/// lists the current version and its download.
struct ElectronProvider: Sendable {
    struct Result: Sendable {
        /// Paths of apps whose feed was fetched and parsed, whether or not it had an update.
        var checkedAppPaths: Set<String> = []
        var updates: [AvailableUpdate] = []
    }

    /// The base URL that `latest-mac.yml` and relative file names resolve against,
    /// or nil if the app doesn't use a feed this provider can read.
    static func feedBaseURL(for app: InstalledApp) -> URL? {
        let configURL = app.url.appendingPathComponent("Contents/Resources/app-update.yml")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        return feedBaseURL(fromConfig: parseYAMLScalars(text))
    }

    static func feedBaseURL(fromConfig config: [String: String]) -> URL? {
        switch config["provider"] {
        case "generic":
            guard let url = config["url"], var base = URL(string: url) else { return nil }
            if !base.absoluteString.hasSuffix("/") { base = URL(string: base.absoluteString + "/")! }
            return base
        case "github":
            guard let owner = config["owner"], let repo = config["repo"] else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/")
        default:
            return nil // s3, spaces, keygen etc. need credentials or vendor APIs.
        }
    }

    func checkForUpdates(apps: [InstalledApp]) async -> Result {
        // Each task yields nil when the feed couldn't be read, or .some(update?) when it could.
        await withTaskGroup(of: (String, AvailableUpdate??).self) { group in
            for app in apps {
                guard let base = Self.feedBaseURL(for: app) else { continue }
                group.addTask {
                    // Not `try?`: it would flatten a failure into "checked, no update".
                    do { return (app.url.path, .some(try await check(app, base: base))) } catch { return (app.url.path, nil) }
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

    private func check(_ app: InstalledApp, base: URL) async throws -> AvailableUpdate? {
        guard let installed = app.shortVersion else { return nil }
        let feedURL = base.appendingPathComponent("latest-mac.yml")
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: feedURL, timeoutInterval: 20))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let release = Self.parseRelease(String(decoding: data, as: UTF8.self), base: base,
                                               appleSilicon: HomebrewCatalogProvider.isAppleSilicon) else {
            throw URLError(.cannotParseResponse)
        }
        guard VersionComparator.isNewer(release.version, than: installed) else { return nil }

        if let minimum = release.minimumSystemVersion {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            if VersionComparator.isNewer(minimum, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") {
                return nil
            }
        }

        return AvailableUpdate(
            app: app,
            newVersion: release.version,
            source: .electron(release.download),
            releaseNotes: release.releaseNotes,
            releaseNotesURL: nil
        )
    }

    // MARK: Parsing

    struct Release: Equatable {
        var version: String
        var download: DirectDownload
        var minimumSystemVersion: String?
        var releaseNotes: String?
    }

    /// Parses `latest-mac.yml`, picking the zip for this architecture
    /// (electron-builder's macOS updater installs from the zip, not the dmg).
    static func parseRelease(_ yaml: String, base: URL, appleSilicon: Bool) -> Release? {
        let top = parseYAMLScalars(yaml)
        guard let version = top["version"] else { return nil }

        let files = parseFiles(yaml)
        let zips = files.filter { $0.url.lowercased().hasSuffix(".zip") }
        let archTagged = { (file: (url: String, sha512: String?)) -> Bool in
            let name = file.url.lowercased()
            return name.contains("arm64") || name.contains("aarch64")
        }
        let intelTagged = { (file: (url: String, sha512: String?)) -> Bool in
            let name = file.url.lowercased()
            return name.contains("x64") || name.contains("x86_64") || name.contains("intel")
        }
        let chosen = appleSilicon
            ? zips.first(where: archTagged) ?? zips.first(where: { !intelTagged($0) })
            : zips.first(where: intelTagged) ?? zips.first(where: { !archTagged($0) })

        let fileName = chosen?.url ?? top["path"]
        let sha512 = chosen?.sha512 ?? top["sha512"]
        guard let fileName, let url = URL(string: fileName, relativeTo: base)?.absoluteURL else { return nil }

        return Release(
            version: version,
            download: DirectDownload(url: url, checksum: sha512.map(Checksum.sha512Base64)),
            minimumSystemVersion: top["minimumSystemVersion"],
            releaseNotes: top["releaseNotes"]
        )
    }

    /// Reads top-level `key: value` lines. These files are machine-written and flat apart
    /// from the `files:` list, so a full YAML parser isn't needed.
    static func parseYAMLScalars(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let first = line.first, !first.isWhitespace, first != "-", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(line[line.index(after: colon)...]))
            if !value.isEmpty { result[key] = value }
        }
        return result
    }

    /// Reads the `files:` list of `- url: …` / `sha512: …` entries.
    static func parseFiles(_ text: String) -> [(url: String, sha512: String?)] {
        var files: [(url: String, sha512: String?)] = []
        var inFiles = false
        for line in text.split(whereSeparator: \.isNewline) {
            if let first = line.first, !first.isWhitespace, first != "-" {
                inFiles = line.hasPrefix("files:")
                continue
            }
            guard inFiles else { continue }
            var entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("- ") {
                entry.removeFirst(2)
                if entry.hasPrefix("url:") { files.append((unquote(String(entry.dropFirst(4))), nil)) }
            } else if entry.hasPrefix("sha512:"), !files.isEmpty {
                files[files.count - 1].sha512 = unquote(String(entry.dropFirst(7)))
            }
        }
        return files
    }

    private static func unquote(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let q = v.first, q == "'" || q == "\"", v.last == q {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}
