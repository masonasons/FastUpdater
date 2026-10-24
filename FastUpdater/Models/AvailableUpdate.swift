import Foundation

/// A digest published alongside a download.
enum Checksum: Sendable, Hashable {
    case sha256Hex(String)
    case sha512Base64(String)
}

/// An app archive (zip, dmg, tar, pkg) to fetch directly from the vendor.
struct DirectDownload: Sendable, Hashable {
    var url: URL
    var checksum: Checksum?
    var headers: [String: String] = [:]
}

/// Where an update comes from, and what's needed to install it.
enum UpdateSource: Sendable, Hashable {
    case sparkle(SparkleRelease)
    case homebrew(token: String)
    case appStore(trackID: Int)
    /// Version from Homebrew's public cask catalog, installed by direct download.
    case caskCatalog(token: String, download: DirectDownload)
    /// electron-builder's `latest-mac.yml` feed.
    case electron(DirectDownload)
    /// Apple's Software Update (`softwareupdate`).
    case systemUpdate(SystemUpdate)

    var displayName: String {
        switch self {
        case .sparkle: return "Sparkle"
        case .homebrew: return "Homebrew"
        case .appStore: return "App Store"
        case .caskCatalog: return "Homebrew Catalog"
        case .electron: return "Electron"
        case .systemUpdate: return "Apple"
        }
    }
}

/// A newer version of an installed app.
struct AvailableUpdate: Sendable, Hashable, Identifiable {
    let app: InstalledApp
    let newVersion: String
    let source: UpdateSource
    /// Plain text or HTML release notes, if the source provides them inline.
    let releaseNotes: String?
    let releaseNotesURL: URL?

    /// The Source column's text.
    var sourceName: String {
        if case .appStore = source, app.isiOSApp { return "App Store (iPhone/iPad)" }
        return source.displayName
    }

    /// System updates share representative app paths, so include the bundle ID too.
    var id: String { "\(app.url.path)|\(app.bundleID)" }
}
