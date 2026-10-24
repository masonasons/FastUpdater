import XCTest
@testable import FastUpdater

private func app(_ name: String, _ bundleID: String, version: String) -> InstalledApp {
    InstalledApp(
        url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, bundleID: bundleID,
        shortVersion: version, buildVersion: nil, sparkleFeedURL: nil, sparklePublicEDKey: nil,
        isFromAppStore: false
    )
}

final class HomebrewCatalogTests: XCTestCase {
    private let catalog = """
    [
      {"token": "stats", "version": "3.0.22", "sha256": "abc123",
       "url": "https://example.com/Stats-arm.dmg",
       "variations": {"tahoe": {"url": "https://example.com/Stats-intel.dmg", "sha256": "def456"}},
       "artifacts": [{"uninstall": [{"quit": "eu.exelban.Stats"}]}, {"app": ["Stats.app"]}]},
      {"token": "block-buzz", "version": "9.9.9", "sha256": "no_check", "url": "https://example.com/buzz.dmg",
       "artifacts": [{"uninstall": [{"quit": "xyz.block.buzz.app"}]}, {"app": ["Buzz.app"]}]},
      {"token": "alfred", "version": "5.8.1,2349", "sha256": "no_check", "url": "https://example.com/alfred.tar.gz",
       "url_specs": {"user_agent": ":fake", "referer": "https://example.com"},
       "artifacts": [{"app": ["Alfred 5.app"]}]},
      {"token": "old-thing", "version": "2.0", "deprecated": true, "url": "https://example.com/old.zip",
       "artifacts": [{"app": ["Old.app"]}]}
    ]
    """

    private func updates(_ apps: [InstalledApp], arm: Bool = true, os: Int = 26) -> [AvailableUpdate] {
        HomebrewCatalogProvider.updates(for: apps, catalogJSON: Data(catalog.utf8), appleSilicon: arm, osMajorVersion: os)
    }

    func testFindsUpdateWithChecksum() {
        let result = updates([app("Stats", "eu.exelban.Stats", version: "3.0.20")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.newVersion, "3.0.22")
        guard case .caskCatalog(let token, let download)? = result.first?.source else { return XCTFail() }
        XCTAssertEqual(token, "stats")
        XCTAssertEqual(download.url.absoluteString, "https://example.com/Stats-arm.dmg")
        XCTAssertEqual(download.checksum, .sha256Hex("abc123"))
    }

    func testIntelUsesVariation() {
        let result = updates([app("Stats", "eu.exelban.Stats", version: "3.0.20")], arm: false)
        guard case .caskCatalog(_, let download)? = result.first?.source else { return XCTFail() }
        XCTAssertEqual(download.url.absoluteString, "https://example.com/Stats-intel.dmg")
        XCTAssertEqual(download.checksum, .sha256Hex("def456"))
    }

    func testRejectsSameNameDifferentApp() {
        XCTAssertTrue(updates([app("Buzz", "com.chidiwilliams.buzz", version: "1.0")]).isEmpty)
    }

    func testAcceptsCaskWithoutIdentifiersAndAppliesURLSpecs() {
        let result = updates([app("Alfred 5", "com.runningwithcrayons.Alfred", version: "5.7.1")])
        XCTAssertEqual(result.first?.newVersion, "5.8.1")
        guard case .caskCatalog(_, let download)? = result.first?.source else { return XCTFail() }
        XCTAssertNil(download.checksum, "no_check means no checksum")
        XCTAssertEqual(download.headers["Referer"], "https://example.com")
        XCTAssertTrue(download.headers["User-Agent"]?.contains("Safari") ?? false)
    }

    func testSkipsUpToDateAndDeprecated() {
        XCTAssertTrue(updates([app("Stats", "eu.exelban.Stats", version: "3.0.22")]).isEmpty)
        XCTAssertTrue(updates([app("Old", "com.example.old", version: "1.0")]).isEmpty)
    }
}

final class ElectronProviderTests: XCTestCase {
    private let base = URL(string: "https://updates.example.com/app/")!
    private let feed = """
    version: 3.27.0
    files:
      - url: MyApp-3.27.0-arm64-mac.zip
        sha512: ARMSHA==
        size: 100
      - url: MyApp-3.27.0-mac.zip
        sha512: X64SHA==
        size: 100
      - url: MyApp-3.27.0-arm64.dmg
        sha512: DMGSHA==
    path: MyApp-3.27.0-mac.zip
    sha512: X64SHA==
    releaseDate: '2026-09-08T11:39:13.368Z'
    minimumSystemVersion: 13.0.0
    """

    func testPicksZipForArchitecture() {
        let arm = ElectronProvider.parseRelease(feed, base: base, appleSilicon: true)
        XCTAssertEqual(arm?.version, "3.27.0")
        XCTAssertEqual(arm?.download.url.absoluteString, "https://updates.example.com/app/MyApp-3.27.0-arm64-mac.zip")
        XCTAssertEqual(arm?.download.checksum, .sha512Base64("ARMSHA=="))
        XCTAssertEqual(arm?.minimumSystemVersion, "13.0.0")

        let intel = ElectronProvider.parseRelease(feed, base: base, appleSilicon: false)
        XCTAssertEqual(intel?.download.url.absoluteString, "https://updates.example.com/app/MyApp-3.27.0-mac.zip")
        XCTAssertEqual(intel?.download.checksum, .sha512Base64("X64SHA=="))
    }

    func testFeedBaseURLs() {
        XCTAssertEqual(
            ElectronProvider.feedBaseURL(fromConfig: ["provider": "generic", "url": "https://x.com/arm64"])?.absoluteString,
            "https://x.com/arm64/")
        XCTAssertEqual(
            ElectronProvider.feedBaseURL(fromConfig: ["provider": "github", "owner": "o", "repo": "r"])?.absoluteString,
            "https://github.com/o/r/releases/latest/download/")
        XCTAssertNil(ElectronProvider.feedBaseURL(fromConfig: ["provider": "s3", "bucket": "b"]))
    }
}

final class SystemUpdateProviderTests: XCTestCase {
    func testParsesListOutput() {
        let output = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: Command Line Tools for Xcode-27.1
        \tTitle: Command Line Tools for Xcode, Version: 27.1, Size: 751464KiB, Recommended: YES,
        * Label: Safari27.1GoldenGateAuto-27.1
        \tTitle: Safari, Version: 27.1, Size: 210303KiB, Recommended: YES,
        * Label: macOS Golden Gate 27.3-27D50
        \tTitle: macOS Golden Gate 27.3, Version: 27.3, Size: 5123456KiB, Recommended: YES, Action: restart,
        """
        let items = SystemUpdateProvider.parse(output)
        XCTAssertEqual(items.map(\.label), [
            "Command Line Tools for Xcode-27.1", "Safari27.1GoldenGateAuto-27.1", "macOS Golden Gate 27.3-27D50",
        ])
        XCTAssertEqual(items[0].title, "Command Line Tools for Xcode")
        XCTAssertEqual(items[0].version, "27.1")
        XCTAssertFalse(items[0].requiresRestart)
        XCTAssertFalse(items[1].isOSUpdate)
        XCTAssertTrue(items[2].isOSUpdate)
        XCTAssertEqual(items[2].action, "restart")
        XCTAssertTrue(items[2].recommended)
    }

    func testNoUpdates() {
        XCTAssertTrue(SystemUpdateProvider.parse("Software Update Tool\n\nFinding available software\nNo new software available.").isEmpty)
    }
}

final class DiskImageTests: XCTestCase {
    func testMountPointFromAttachPlistWithLicensePreamble() {
        let output = """
        Software License Agreement
        Blah blah.
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>system-entities</key><array>
          <dict><key>content-hint</key><string>GUID_partition_scheme</string><key>dev-entry</key><string>/dev/disk15</string></dict>
          <dict><key>content-hint</key><string>Apple_HFS</string><key>mount-point</key><string>/Volumes/Stats</string></dict>
        </array></dict></plist>
        """
        XCTAssertEqual(ArchiveInstaller.mountPoint(fromAttachPlist: output)?.path, "/Volumes/Stats")
        XCTAssertNil(ArchiveInstaller.mountPoint(fromAttachPlist: "hdiutil: attach failed"))
    }
}

final class WrappediOSAppTests: XCTestCase {
    func testReadsWrapperMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Mastodon.app")
        let wrapper = app.appendingPathComponent("Wrapper")
        try FileManager.default.createDirectory(at: wrapper.appendingPathComponent("Mastodon.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metadata: [String: Any] = [
            "itemId": 1571998974, "itemName": "Mastodon", "softwareVersionBundleId": "org.joinmastodon.app",
            "bundleShortVersionString": "2026.07", "bundleVersion": "8001", "storefrontCountryCode": "gb",
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: wrapper.appendingPathComponent("iTunesMetadata.plist"))

        let scanned = try XCTUnwrap(AppScanner.readApp(at: app))
        XCTAssertTrue(scanned.isiOSApp)
        XCTAssertTrue(scanned.isFromAppStore)
        XCTAssertEqual(scanned.name, "Mastodon")
        XCTAssertEqual(scanned.bundleID, "org.joinmastodon.app")
        XCTAssertEqual(scanned.shortVersion, "2026.07")
        XCTAssertEqual(scanned.appStoreID, 1571998974)
        XCTAssertEqual(scanned.storeCountry, "gb")
    }
}
