import Foundation

/// One `<item>` from a Sparkle appcast.
struct SparkleRelease: Sendable, Hashable {
    var title: String?
    /// sparkle:version, compared against the app's CFBundleVersion.
    var version: String?
    /// sparkle:shortVersionString, shown to the user.
    var shortVersion: String?
    var enclosureURL: URL?
    var enclosureLength: Int64?
    var edSignature: String?
    var minimumSystemVersion: String?
    var channel: String?
    var os: String?
    var releaseNotesURL: URL?
    var descriptionHTML: String?

    var displayVersion: String { shortVersion ?? version ?? "?" }
}

/// Parses Sparkle appcast (RSS) feeds.
final class AppcastParser: NSObject, XMLParserDelegate {
    private var releases: [SparkleRelease] = []
    private var current: SparkleRelease?
    private var text = ""
    private var deltasDepth = 0

    static func parse(_ data: Data) throws -> [SparkleRelease] {
        let delegate = AppcastParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return delegate.releases
    }

    /// Picks the newest release that is installable on this Mac and on the default channel.
    static func bestRelease(
        in releases: [SparkleRelease],
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> SparkleRelease? {
        let os = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        return releases
            .filter { release in
                guard release.enclosureURL != nil, release.version != nil else { return false }
                if let channel = release.channel, !channel.isEmpty { return false }
                if let target = release.os, target.lowercased() != "macos" { return false }
                if let minimum = release.minimumSystemVersion,
                   VersionComparator.isNewer(minimum, than: os) { return false }
                return true
            }
            .max { VersionComparator.compare($0.version!, $1.version!) == .orderedAscending }
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        text = ""
        switch name {
        case "item":
            current = SparkleRelease()
        case "sparkle:deltas":
            deltasDepth += 1
        case "enclosure" where current != nil && deltasDepth == 0:
            if let url = attributes["url"]?.trimmingCharacters(in: .whitespaces) {
                current?.enclosureURL = URL(string: url)
            }
            current?.enclosureLength = attributes["length"].flatMap { Int64($0) }
            current?.edSignature = attributes["sparkle:edSignature"]
            current?.os = attributes["sparkle:os"]
            // Older feeds put the versions on the enclosure instead of the item.
            if current?.version == nil { current?.version = attributes["sparkle:version"] }
            if current?.shortVersion == nil { current?.shortVersion = attributes["sparkle:shortVersionString"] }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement name: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { text = "" }

        if name == "sparkle:deltas" {
            deltasDepth = max(0, deltasDepth - 1)
            return
        }
        guard current != nil, deltasDepth == 0 else { return }

        switch name {
        case "item":
            if let item = current { releases.append(item) }
            current = nil
        case "title": current?.title = value
        case "sparkle:version": current?.version = value
        case "sparkle:shortVersionString": current?.shortVersion = value
        case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
        case "sparkle:channel": current?.channel = value
        case "sparkle:releaseNotesLink": current?.releaseNotesURL = URL(string: value)
        case "description": current?.descriptionHTML = value.isEmpty ? nil : value
        default: break
        }
    }
}
