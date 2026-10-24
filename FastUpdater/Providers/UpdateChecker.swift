import Foundation

/// Scans installed apps and asks each provider about the apps it's responsible for.
///
/// Each app is owned by exactly one source, in order of preference: App Store apps go
/// to the App Store, cask-installed apps to Homebrew, apps with an appcast to Sparkle,
/// apps with an electron-builder feed to Electron, and anything left over — including apps
/// whose own feed couldn't be read — is looked up in Homebrew's cask catalog.
struct UpdateChecker: Sendable {
    struct Report: Sendable {
        var scannedCount = 0
        var updates: [AvailableUpdate] = []
        var errors: [String] = []
    }

    var scanner = AppScanner()
    var sparkle = SparkleProvider()
    var electron = ElectronProvider()
    var homebrew = HomebrewProvider()
    var catalog = HomebrewCatalogProvider()
    var appStore = AppStoreProvider()
    var system = SystemUpdateProvider()
    /// Apple Software Update is opt-in: it's slow to scan and installs need an admin.
    var includeSystemUpdates = false

    func check() async -> Report {
        let apps = scanner.scan()
        let nonStoreApps = apps.filter { !$0.isFromAppStore }
        let sparkleApps = nonStoreApps.filter { $0.sparkleFeedURL != nil }
        let electronApps = nonStoreApps.filter { $0.sparkleFeedURL == nil && ElectronProvider.feedBaseURL(for: $0) != nil }

        async let sparkleUpdates = sparkle.checkForUpdates(apps: sparkleApps)
        async let electronUpdates = electron.checkForUpdates(apps: electronApps)
        async let brewResult = Result { try await homebrew.checkForUpdates(apps: nonStoreApps) }
        // The catalog checks every non-store app; results for apps another source answered are dropped below.
        async let catalogResult = Result { try await catalog.checkForUpdates(apps: nonStoreApps) }
        async let storeResult = Result { try await appStore.checkForUpdates(apps: apps) }
        async let systemResult = Result { [includeSystemUpdates, system] in
            includeSystemUpdates ? try await system.checkForUpdates() : []
        }

        var report = Report(scannedCount: apps.count)
        var brewManaged = Set<String>()

        switch await brewResult {
        case .success(let result):
            brewManaged = result.managedAppPaths
            report.updates += result.updates
        case .failure(let error):
            report.errors.append("Homebrew: \(error.localizedDescription)")
        }

        switch await storeResult {
        case .success(let updates): report.updates += updates
        case .failure(let error): report.errors.append("App Store: \(error.localizedDescription)")
        }

        let sparkle = await sparkleUpdates
        let electron = await electronUpdates
        report.updates += (sparkle.updates + electron.updates).filter { !brewManaged.contains($0.app.url.path) }

        let answered = brewManaged.union(sparkle.checkedAppPaths).union(electron.checkedAppPaths)
        switch await catalogResult {
        case .success(let updates): report.updates += updates.filter { !answered.contains($0.app.url.path) }
        case .failure(let error): report.errors.append("Homebrew catalog: \(error.localizedDescription)")
        }
        switch await systemResult {
        case .success(let updates): report.updates += updates
        case .failure(let error): report.errors.append("Software Update: \(error.localizedDescription)")
        }

        report.updates.sort { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        return report
    }
}

private extension Result where Failure == Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
