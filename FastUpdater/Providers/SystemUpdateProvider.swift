import Foundation

/// One item from `softwareupdate --list`.
struct SystemUpdate: Sendable, Hashable {
    let label: String
    let title: String
    let version: String
    let recommended: Bool
    /// "restart" or "shut down" when the update can't finish without one.
    let action: String?

    var requiresRestart: Bool { action != nil }
    /// Whole-OS updates. On Apple silicon these need the Mac owner's credentials,
    /// so they're handed to System Settings rather than installed from here.
    var isOSUpdate: Bool { title.hasPrefix("macOS") }
}

/// Checks Apple's Software Update for macOS, Safari, Command Line Tools and similar updates.
/// Opt-in, because a scan takes several seconds and installs need an administrator.
struct SystemUpdateProvider: Sendable {
    func checkForUpdates() async throws -> [AvailableUpdate] {
        let result = try await Shell.runChecked("/usr/sbin/softwareupdate", ["--list"])
        return Self.parse(result.stdout + "\n" + result.stderr).map(Self.availableUpdate)
    }

    /// Parses `softwareupdate --list` output:
    ///
    ///     * Label: Safari26.1SequoiaAuto-26.1
    ///         Title: Safari, Version: 26.1, Size: 210303KiB, Recommended: YES,
    ///     * Label: macOS Golden Gate 27.3-27D50
    ///         Title: macOS Golden Gate 27.3, Version: 27.3, Size: 5123456KiB, Recommended: YES, Action: restart,
    static func parse(_ output: String) -> [SystemUpdate] {
        var updates: [SystemUpdate] = []
        var label: String?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("* Label:") {
                label = line.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces)
            } else if let current = label, line.hasPrefix("Title:") {
                let fields = parseFields(line)
                if let title = fields["Title"], let version = fields["Version"] {
                    updates.append(SystemUpdate(
                        label: current,
                        title: title,
                        version: version,
                        recommended: fields["Recommended"]?.uppercased() == "YES",
                        action: fields["Action"].flatMap { $0.isEmpty ? nil : $0 }
                    ))
                }
                label = nil
            }
        }
        return updates
    }

    /// Splits "Title: X, Version: 1.0, Size: 12KiB," into a dictionary.
    /// Titles can contain commas, so only split before a known key.
    private static func parseFields(_ line: String) -> [String: String] {
        let keys = ["Title", "Version", "Size", "Recommended", "Action"]
        var fields: [String: String] = [:]
        var positions: [(key: String, range: Range<String.Index>)] = []
        for key in keys {
            let marker = key == "Title" ? "Title: " : ", \(key): "
            if let range = line.range(of: marker) { positions.append((key, range)) }
        }
        positions.sort { $0.range.lowerBound < $1.range.lowerBound }
        for (index, entry) in positions.enumerated() {
            let end = index + 1 < positions.count ? positions[index + 1].range.lowerBound : line.endIndex
            var value = String(line[entry.range.upperBound..<end]).trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(",") { value.removeLast() }
            fields[entry.key] = value
        }
        return fields
    }

    // MARK: Presenting

    private static func availableUpdate(_ item: SystemUpdate) -> AvailableUpdate {
        let (appPath, installedVersion) = relatedApp(for: item)
        let app = InstalledApp(
            url: URL(fileURLWithPath: appPath),
            name: item.title,
            bundleID: "com.apple.softwareupdate.\(item.label)",
            shortVersion: installedVersion,
            buildVersion: nil,
            sparkleFeedURL: nil,
            sparklePublicEDKey: nil,
            isFromAppStore: false
        )

        var notes: [String] = []
        if item.isOSUpdate { notes.append("This macOS update is installed from System Settings › Software Update.") }
        if let action = item.action { notes.append("Your Mac must \(action) to finish installing this update.") }
        if !item.recommended { notes.append("Apple doesn't mark this update as recommended.") }

        return AvailableUpdate(
            app: app,
            newVersion: item.version,
            source: .systemUpdate(item),
            releaseNotes: notes.isEmpty ? nil : notes.joined(separator: "\n"),
            releaseNotesURL: nil
        )
    }

    /// An app whose icon and version best represent the update in the list.
    private static func relatedApp(for item: SystemUpdate) -> (path: String, version: String?) {
        if item.isOSUpdate {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let version = os.patchVersion == 0
                ? "\(os.majorVersion).\(os.minorVersion)"
                : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            return ("/System/Applications/System Settings.app", version)
        }
        if item.title.hasPrefix("Safari") {
            let safari = "/Applications/Safari.app"
            return (safari, Bundle(path: safari)?.infoDictionary?["CFBundleShortVersionString"] as? String)
        }
        if item.title.contains("Command Line Tools") {
            return ("/System/Applications/Utilities/Terminal.app", nil)
        }
        return ("/System/Library/CoreServices/Software Update.app", nil)
    }
}
