import AppKit

enum InstallOutcome: Sendable {
    /// The new version is in place.
    case installed
    /// The update was handed to another app (App Store, Installer) to finish.
    case handedOff(String)
}

struct InstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Installs a single update, dispatching on its source.
struct UpdateInstaller: Sendable {
    typealias Progress = @Sendable (String) -> Void

    /// Asked, with the app's name, whether to force quit an app that ignored a normal quit.
    var confirmForceQuit: @Sendable (String) async -> Bool = { _ in false }

    func install(_ update: AvailableUpdate, progress: @escaping Progress) async throws -> InstallOutcome {
        switch update.source {
        case .appStore(let trackID):
            return try await installFromAppStore(trackID: trackID, isiOSApp: update.app.isiOSApp, progress: progress)

        case .homebrew(let token):
            return try await withAppQuit(update.app, progress: progress) {
                try await installWithHomebrew(token: token, progress: progress)
            }

        case .sparkle(let release):
            guard let url = release.enclosureURL else { throw InstallError("The update has no download.") }
            let installer = ArchiveInstaller(
                app: update.app,
                download: DirectDownload(url: url),
                signatureCheck: .sparkleEdDSA(signature: release.edSignature)
            )
            return try await withAppQuit(update.app, progress: progress) {
                try await installer.install(progress: progress)
            }

        case .systemUpdate(let item):
            return try await installSystemUpdate(item, progress: progress)

        case .caskCatalog(_, let download), .electron(let download):
            let installer = ArchiveInstaller(app: update.app, download: download)
            return try await withAppQuit(update.app, progress: progress) {
                try await installer.install(progress: progress)
            }
        }
    }

    // MARK: App Store

    private func installFromAppStore(trackID: Int, isiOSApp: Bool, progress: Progress) async throws -> InstallOutcome {
        // mas only manages Mac apps; iPhone/iPad apps are updated from their App Store page.
        if !isiOSApp, let mas = Shell.findTool("mas") {
            progress("Updating via App Store…")
            let result = try await Shell.run(mas, ["upgrade", String(trackID)], environment: Self.askpassEnvironment)
            if result.succeeded { return .installed }
        }
        // mas isn't installed or couldn't do it (e.g. not signed in): let the App Store finish.
        let url = URL(string: "macappstore://apps.apple.com/app/id\(trackID)")!
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        return .handedOff(isiOSApp ? "Opened in App Store. Click Update there" : "Opened in App Store")
    }

    // MARK: Apple Software Update

    private func installSystemUpdate(_ item: SystemUpdate, progress: Progress) async throws -> InstallOutcome {
        if item.isOSUpdate {
            // Apple silicon needs the Mac owner's credentials for OS updates; System Settings asks properly.
            let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return .handedOff("Opened in System Settings")
        }

        progress("Installing (this can take several minutes)…")
        // softwareupdate needs root. Pass the label as an argument and quote it in AppleScript
        // so a label can't inject shell code.
        let appleScript = """
        on run argv
            do shell script "/usr/sbin/softwareupdate --install --agree-to-license " & ¬
                quoted form of (item 1 of argv) with administrator privileges
        end run
        """
        let result = try await Shell.run("/usr/bin/osascript", ["-e", appleScript, item.label])
        guard result.succeeded else {
            if result.stderr.contains("-128") { throw InstallError("Cancelled.") }
            throw ShellError(command: "softwareupdate", result: result)
        }
        if item.requiresRestart { return .handedOff("Installed. \(item.action!.capitalized) to finish") }
        return .installed
    }

    // MARK: Homebrew

    private func installWithHomebrew(token: String, progress: Progress) async throws -> InstallOutcome {
        guard let brew = HomebrewProvider.brewPath else { throw InstallError("Homebrew isn't installed.") }
        progress("Running brew upgrade…")
        var env = Self.askpassEnvironment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        try await Shell.runChecked(brew, ["upgrade", "--cask", token], environment: env)
        return .installed
    }

    /// Lets `sudo -A` (used by Homebrew and mas) ask for the password in a dialog
    /// rather than failing for want of a terminal.
    private static let askpassEnvironment: [String: String] = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastUpdater", isDirectory: true)
        let script = dir.appendingPathComponent("askpass.sh")
        let body = """
        #!/bin/sh
        exec /usr/bin/osascript -e 'text returned of (display dialog "An administrator password is needed to finish this update." default answer "" with hidden answer with title "FastUpdater" with icon caution)'

        """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return ["SUDO_ASKPASS": script.path]
        } catch {
            return [:]
        }
    }()

    // MARK: Quitting and relaunching

    /// Quits the app if it's running, runs `body`, then relaunches it if it was running.
    private func withAppQuit(
        _ app: InstalledApp,
        progress: Progress,
        _ body: () async throws -> InstallOutcome
    ) async throws -> InstallOutcome {
        let wasRunning = try await quit(app, progress: progress)
        let outcome = try await body()
        if wasRunning, case .installed = outcome {
            progress("Relaunching…")
            let url = app.url
            await MainActor.run {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
        }
        return outcome
    }

    private func quit(_ app: InstalledApp, progress: Progress) async throws -> Bool {
        let running = await MainActor.run { Self.runningInstances(of: app) }
        guard !running.isEmpty else { return false }

        progress("Quitting \(app.name)…")
        await MainActor.run { running.forEach { $0.terminate() } }
        if try await waitForExit(of: app, seconds: 10) { return true }

        // Menu bar apps and apps with background servers often ignore a normal quit.
        progress("Waiting for permission to force quit…")
        guard await confirmForceQuit(app.name) else {
            throw InstallError("\(app.name) didn't quit. Quit it and try again.")
        }
        progress("Force quitting \(app.name)…")
        await MainActor.run { Self.runningInstances(of: app).forEach { $0.forceTerminate() } }
        if try await waitForExit(of: app, seconds: 5) { return true }
        throw InstallError("\(app.name) couldn't be quit.")
    }

    private func waitForExit(of app: InstalledApp, seconds: Int) async throws -> Bool {
        for _ in 0..<(seconds * 4) {
            try await Task.sleep(for: .milliseconds(250))
            if await MainActor.run(body: { Self.runningInstances(of: app).isEmpty }) { return true }
        }
        return false
    }

    @MainActor
    static func runningInstances(of app: InstalledApp) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .filter { $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }
    }
}
