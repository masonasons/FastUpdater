import Foundation

/// An application bundle found on disk.
struct InstalledApp: Sendable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    /// CFBundleShortVersionString, the user-facing version.
    let shortVersion: String?
    /// CFBundleVersion, the build number Sparkle compares against.
    let buildVersion: String?
    /// Sparkle appcast URL (SUFeedURL), if the app declares one.
    let sparkleFeedURL: URL?
    /// Sparkle EdDSA public key (SUPublicEDKey), base64.
    let sparklePublicEDKey: String?
    /// True when the bundle carries a Mac App Store receipt, or is an iPhone/iPad app from the store.
    let isFromAppStore: Bool
    /// iPhone/iPad app running on Apple silicon (installed as a wrapper bundle).
    var isiOSApp = false
    /// App Store item ID, when known from the install metadata.
    var appStoreID: Int?
    /// Two-letter code of the App Store country the app was bought from.
    var storeCountry: String?

    var displayVersion: String {
        switch (shortVersion, buildVersion) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        case let (nil, build?): return build
        default: return "Unknown"
        }
    }
}
