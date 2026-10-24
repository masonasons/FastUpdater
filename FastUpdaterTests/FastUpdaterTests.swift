import XCTest
@testable import FastUpdater

final class VersionComparatorTests: XCTestCase {
    func testOrdering() {
        let ascending = ["1.0a1", "1.0b1", "1.0b2", "1.0", "1.0.1", "1.1", "1.10", "2", "10.0"]
        for (older, newer) in zip(ascending, ascending.dropFirst()) {
            XCTAssertTrue(VersionComparator.isNewer(newer, than: older), "\(newer) should be newer than \(older)")
            XCTAssertFalse(VersionComparator.isNewer(older, than: newer), "\(older) should not be newer than \(newer)")
        }
    }

    func testEquality() {
        XCTAssertEqual(VersionComparator.compare("1.2.3", "1.2.3"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("1.2-3", "1.2.3"), .orderedSame)
    }

    func testLargeBuildNumbers() {
        XCTAssertTrue(VersionComparator.isNewer("20240115", than: "20231201"))
    }
}

final class AppcastParserTests: XCTestCase {
    private let feed = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <item>
          <title>Version 2.1</title>
          <sparkle:version>210</sparkle:version>
          <sparkle:shortVersionString>2.1</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
          <description><![CDATA[<ul><li>Fixes</li></ul>]]></description>
          <enclosure url="https://example.com/App-2.1.zip" length="100" type="application/octet-stream"
                     sparkle:edSignature="abc=="/>
          <sparkle:deltas>
            <enclosure url="https://example.com/delta.delta" sparkle:deltaFrom="200" sparkle:version="210"/>
          </sparkle:deltas>
        </item>
        <item>
          <title>Version 3.0 beta</title>
          <sparkle:version>300</sparkle:version>
          <sparkle:channel>beta</sparkle:channel>
          <enclosure url="https://example.com/App-3.0b.zip" length="100" type="application/octet-stream"/>
        </item>
        <item>
          <title>Version 2.5 (future OS)</title>
          <sparkle:version>250</sparkle:version>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion>
          <enclosure url="https://example.com/App-2.5.zip" length="100" type="application/octet-stream"/>
        </item>
        <item>
          <title>Version 2.0</title>
          <enclosure url="https://example.com/App-2.0.zip" sparkle:version="200"
                     sparkle:shortVersionString="2.0" length="100" type="application/octet-stream"/>
        </item>
      </channel>
    </rss>
    """

    func testParsesItemsAndIgnoresDeltas() throws {
        let releases = try AppcastParser.parse(Data(feed.utf8))
        XCTAssertEqual(releases.count, 4)
        XCTAssertEqual(releases[0].enclosureURL?.absoluteString, "https://example.com/App-2.1.zip")
        XCTAssertEqual(releases[0].edSignature, "abc==")
        XCTAssertEqual(releases[0].descriptionHTML, "<ul><li>Fixes</li></ul>")
        XCTAssertEqual(releases[3].version, "200", "falls back to enclosure attributes")
    }

    func testBestReleaseSkipsBetaAndIncompatible() throws {
        let releases = try AppcastParser.parse(Data(feed.utf8))
        let best = AppcastParser.bestRelease(
            in: releases,
            osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertEqual(best?.version, "210")
        XCTAssertEqual(best?.displayVersion, "2.1")
    }
}

final class HomebrewParsingTests: XCTestCase {
    func testAppArtifactsWithRename() {
        let json = """
        {"casks": [
          {"token": "foo", "artifacts": [{"app": ["Foo.app"]}, {"zap": []}]},
          {"token": "bar", "artifacts": [{"app": ["Bar Beta.app", {"target": "Bar.app"}]}]},
          {"token": "cli-only", "artifacts": [{"binary": ["tool"]}]}
        ]}
        """
        XCTAssertEqual(HomebrewProvider.appArtifacts(fromInfoJSON: json), ["Foo.app": "foo", "Bar.app": "bar"])
    }

    func testOutdated() {
        let json = """
        {"formulae": [], "casks": [{"name": "foo", "installed_versions": ["1.0"], "current_version": "1.2,99"}]}
        """
        XCTAssertEqual(HomebrewProvider.outdatedCasks(fromJSON: json), ["foo": "1.2,99"])
    }
}
