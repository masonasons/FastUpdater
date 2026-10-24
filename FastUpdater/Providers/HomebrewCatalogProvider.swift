import Foundation

/// Checks apps that have no updater of their own against Homebrew's public cask catalog,
/// which tracks the latest version and download for thousands of Mac apps.
/// Homebrew itself isn't needed: updates are downloaded straight from the vendor.
struct HomebrewCatalogProvider: Sendable {
    static let catalogURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    /// How long a downloaded catalog is reused before fetching a fresh one.
    var maxCacheAge: TimeInterval = 6 * 60 * 60

    func checkForUpdates(apps: [InstalledApp]) async throws -> [AvailableUpdate] {
        guard !apps.isEmpty else { return [] }
        let data = try await catalogData()
        let isARM = Self.isAppleSilicon
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return Self.updates(for: apps, catalogJSON: data, appleSilicon: isARM, osMajorVersion: osMajor)
    }

    /// Matches apps to casks and returns those with a newer catalog version.
    static func updates(
        for apps: [InstalledApp],
        catalogJSON: Data,
        appleSilicon: Bool,
        osMajorVersion: Int
    ) -> [AvailableUpdate] {
        guard let casks = try? JSONSerialization.jsonObject(with: catalogJSON) as? [[String: Any]] else { return [] }

        let wanted = Set(apps.map(\.url.lastPathComponent))
        var casksByAppName: [String: [[String: Any]]] = [:]
        for cask in casks where (cask["deprecated"] as? Bool) != true && (cask["disabled"] as? Bool) != true {
            for name in appNames(in: cask) where wanted.contains(name) {
                casksByAppName[name, default: []].append(cask)
            }
        }

        return apps.compactMap { app in
            guard let installed = app.shortVersion,
                  let cask = casksByAppName[app.url.lastPathComponent]?.first(where: { isSameApp(app, as: $0) }),
                  let token = cask["token"] as? String,
                  let rawVersion = cask["version"] as? String,
                  let download = download(for: cask, appleSilicon: appleSilicon, osMajorVersion: osMajorVersion)
            else { return nil }

            // "1.2.3,4567" → "1.2.3"; "latest" means the cask doesn't track versions.
            let version = rawVersion.split(separator: ",").first.map(String.init) ?? rawVersion
            guard version != "latest", VersionComparator.isNewer(version, than: installed) else { return nil }

            return AvailableUpdate(
                app: app,
                newVersion: version,
                source: .caskCatalog(token: token, download: download),
                releaseNotes: nil,
                releaseNotesURL: (cask["homepage"] as? String).flatMap(URL.init(string:))
            )
        }
    }

    // MARK: Matching

    /// The installed names of a cask's `.app` artifacts (honouring `target:` renames).
    static func appNames(in cask: [String: Any]) -> [String] {
        guard let artifacts = cask["artifacts"] as? [[String: Any]] else { return [] }
        var names: [String] = []
        for artifact in artifacts {
            guard let entries = artifact["app"] as? [Any] else { continue }
            for entry in entries {
                if let name = entry as? String {
                    names.append((name as NSString).lastPathComponent)
                } else if let options = entry as? [String: Any], let target = options["target"] as? String {
                    if !names.isEmpty { names.removeLast() }
                    names.append((target as NSString).lastPathComponent)
                }
            }
        }
        return names
    }

    /// App names collide ("Buzz.app" is two unrelated apps), so confirm with the bundle ID.
    /// Most casks name it in their `uninstall`/`zap` stanzas. If a cask declares bundle IDs
    /// to quit and ours isn't among them, it's a different app. Casks that name nothing are
    /// accepted on the app name; the code-signing team check at install time backs that up.
    static func isSameApp(_ app: InstalledApp, as cask: [String: Any]) -> Bool {
        guard let artifacts = cask["artifacts"] as? [[String: Any]] else { return false }
        let stanzas = artifacts.compactMap { $0["uninstall"] ?? $0["zap"] }
        guard let data = try? JSONSerialization.data(withJSONObject: stanzas),
              let text = String(data: data, encoding: .utf8)?.lowercased() else { return false }

        if text.contains(app.bundleID.lowercased()) { return true }
        return !text.contains("\"quit\"")
    }

    // MARK: Downloads

    /// Picks the download for this Mac. The top-level url is the Apple silicon build for the
    /// newest macOS; `variations` override it per OS, keyed `arm64_<codename>` for Apple
    /// silicon and plain `<codename>` for Intel.
    static func download(for cask: [String: Any], appleSilicon: Bool, osMajorVersion: Int) -> DirectDownload? {
        var urlString = cask["url"] as? String
        var sha256 = cask["sha256"] as? String

        let variations = cask["variations"] as? [String: [String: Any]] ?? [:]
        if let codename = macOSCodenames[osMajorVersion] {
            let key = appleSilicon ? "arm64_\(codename)" : codename
            if let variation = variations[key] {
                urlString = variation["url"] as? String ?? urlString
                sha256 = variation["sha256"] as? String ?? sha256
            }
        } else if !appleSilicon {
            return nil // An Intel Mac on an OS the catalog doesn't know; don't guess.
        }

        guard let urlString, let url = URL(string: urlString) else { return nil }

        var headers: [String: String] = [:]
        if let specs = cask["url_specs"] as? [String: Any] {
            // POST forms and git checkouts can't be fetched as a plain download.
            if specs["using"] != nil || specs["data"] != nil || specs["branch"] != nil { return nil }
            if let agent = specs["user_agent"] as? String {
                headers["User-Agent"] = agent == ":fake" ? safariUserAgent : agent
            }
            if let referer = specs["referer"] as? String { headers["Referer"] = referer }
            if let cookies = specs["cookies"] as? [String: String] {
                headers["Cookie"] = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            }
        }

        let checksum = sha256.flatMap { $0 == "no_check" ? nil : Checksum.sha256Hex($0) }
        return DirectDownload(url: url, checksum: checksum, headers: headers)
    }

    static let macOSCodenames: [Int: String] = [
        11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma",
        15: "sequoia", 26: "tahoe", 27: "golden_gate",
    ]

    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    // MARK: Catalog cache

    private func catalogData() async throws -> Data {
        let fm = FileManager.default
        let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fastupdater.FastUpdater", isDirectory: true)
        let cacheFile = cacheDir.appendingPathComponent("cask.json")

        let modified = (try? fm.attributesOfItem(atPath: cacheFile.path)[.modificationDate]) as? Date
        if let modified, Date().timeIntervalSince(modified) < maxCacheAge,
           let cached = try? Data(contentsOf: cacheFile) {
            return cached
        }

        do {
            let request = URLRequest(url: Self.catalogURL, timeoutInterval: 60)
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw InstallError("The Homebrew catalog returned HTTP \(http.statusCode).")
            }
            try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            return data
        } catch {
            // Offline or the server is down: a stale catalog beats none.
            if let cached = try? Data(contentsOf: cacheFile) { return cached }
            throw error
        }
    }
}
