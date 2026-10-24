import Foundation

/// Finds application bundles in the standard Applications folders.
struct AppScanner: Sendable {
    var searchDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    func scan() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []

        for directory in searchDirectories {
            for url in appBundles(in: directory, depth: 2) {
                let resolved = url.resolvingSymlinksInPath()
                guard seen.insert(resolved.path).inserted,
                      let app = Self.readApp(at: resolved) else { continue }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Lists `.app` bundles, descending into plain folders (e.g. /Applications/Utilities)
    /// but never into the bundles themselves.
    private func appBundles(in directory: URL, depth: Int) -> [URL] {
        guard depth > 0,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return [] }

        return contents.flatMap { url -> [URL] in
            if url.pathExtension == "app" { return [url] }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? appBundles(in: url, depth: depth - 1) : []
        }
    }

    static func readApp(at url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        if !FileManager.default.fileExists(atPath: plistURL.path) {
            return readWrappediOSApp(at: url)
        }
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let feed = (plist["SUFeedURL"] as? String)
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")

        return InstalledApp(
            url: url,
            name: name,
            bundleID: bundleID,
            shortVersion: plist["CFBundleShortVersionString"] as? String,
            buildVersion: plist["CFBundleVersion"] as? String,
            sparkleFeedURL: feed,
            sparklePublicEDKey: plist["SUPublicEDKey"] as? String,
            isFromAppStore: FileManager.default.fileExists(atPath: receipt.path)
        )
    }

    /// iPhone and iPad apps on Apple silicon are installed as `Name.app/Wrapper/Name.app`,
    /// with the App Store's install record in `Wrapper/iTunesMetadata.plist`.
    static func readWrappediOSApp(at url: URL) -> InstalledApp? {
        let metadataURL = url.appendingPathComponent("Wrapper/iTunesMetadata.plist")
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let itemID = (metadata["itemId"] as? NSNumber)?.intValue,
              let bundleID = metadata["softwareVersionBundleId"] as? String else { return nil }

        return InstalledApp(
            url: url,
            name: (metadata["itemName"] as? String) ?? url.deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            shortVersion: metadata["bundleShortVersionString"] as? String,
            buildVersion: metadata["bundleVersion"] as? String,
            sparkleFeedURL: nil,
            sparklePublicEDKey: nil,
            isFromAppStore: true,
            isiOSApp: true,
            appStoreID: itemID,
            storeCountry: metadata["storefrontCountryCode"] as? String
        )
    }
}
