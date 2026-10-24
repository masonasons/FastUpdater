import AppKit
import CryptoKit
import Security

/// Downloads an app archive, verifies it, and swaps it in for the installed app.
///
/// The archive must match its published checksum and, for Sparkle apps with an EdDSA key,
/// the developer's signature. The new bundle must be validly code-signed by the same team
/// as the installed one.
struct ArchiveInstaller: Sendable {
    enum SignatureCheck: Sendable {
        case none
        /// Sparkle's EdDSA signature from the appcast, checked against the app's SUPublicEDKey.
        case sparkleEdDSA(signature: String?)
    }

    let app: InstalledApp
    let download: DirectDownload
    var signatureCheck: SignatureCheck = .none

    private enum ArchiveKind { case zip, tar, dmg, pkg }

    func install(progress: UpdateInstaller.Progress) async throws -> InstallOutcome {
        // A scratch directory on the same volume as the app keeps the final move cheap.
        let workDir = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app.url, create: true
        )
        var mountPoint: URL?
        defer {
            if let mountPoint {
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", mountPoint.path, "-force"])
            }
        }

        progress("Downloading…")
        let archive = try await fetch(into: workDir)

        progress("Verifying…")
        try verifyChecksum(of: archive)
        try verifyEdSignature(of: archive)

        let kind = try archiveKind(of: archive)
        let searchRoot: URL
        switch kind {
        case .pkg:
            // Installer packages can do anything; let Installer.app show the user what it'll do.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(archive.lastPathComponent)
            try? FileManager.default.removeItem(at: keep)
            try FileManager.default.moveItem(at: archive, to: keep)
            try? FileManager.default.removeItem(at: workDir)
            await MainActor.run { _ = NSWorkspace.shared.open(keep) }
            return .handedOff("Opened in Installer")
        case .zip:
            progress("Extracting…")
            searchRoot = workDir.appendingPathComponent("extracted")
            try await Shell.runChecked("/usr/bin/ditto", ["-x", "-k", archive.path, searchRoot.path])
        case .tar:
            progress("Extracting…")
            searchRoot = workDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: searchRoot, withIntermediateDirectories: true)
            try await Shell.runChecked("/usr/bin/tar", ["-xf", archive.path, "-C", searchRoot.path])
        case .dmg:
            progress("Opening disk image…")
            let mount = try await attachDiskImage(archive)
            mountPoint = mount
            searchRoot = mount
        }

        // Surface unreadable locations as themselves rather than as "app not found".
        _ = try FileManager.default.contentsOfDirectory(at: searchRoot, includingPropertiesForKeys: nil)
        guard let newApp = findApp(in: searchRoot, depth: 3) else {
            throw InstallError("The download doesn't contain \(app.name).")
        }
        try verifyCodeSignature(of: newApp)

        progress("Installing…")
        try await replace(app.url, with: newApp, backupDir: workDir)
        if let mount = mountPoint {
            _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            mountPoint = nil
        }
        try? FileManager.default.removeItem(at: workDir)
        return .installed
    }

    // MARK: Disk images

    /// Mounts a disk image hidden from Finder and returns where it was mounted.
    ///
    /// The mount point is left to hdiutil (under /Volumes): macOS refuses this process read
    /// access to an image mounted inside its own item-replacement directory.
    private func attachDiskImage(_ image: URL) async throws -> URL {
        // "Y" accepts any license agreement embedded in the image.
        let result = try await Shell.runChecked(
            "/usr/bin/hdiutil",
            ["attach", image.path, "-nobrowse", "-noautoopen", "-noverify", "-plist"],
            input: "Y\n"
        )
        guard let mount = Self.mountPoint(fromAttachPlist: result.stdout) else {
            throw InstallError("The disk image didn't mount.")
        }
        return mount
    }

    /// Reads the first mount point from `hdiutil attach -plist` output. A license agreement,
    /// if the image has one, is printed before the plist, so skip to the XML.
    static func mountPoint(fromAttachPlist output: String) -> URL? {
        guard let start = output.range(of: "<?xml"),
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(output[start.lowerBound...].utf8), format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.lazy.compactMap({ $0["mount-point"] as? String }).first
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: Download

    private func fetch(into dir: URL) async throws -> URL {
        let url = download.url
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("FastUpdater/0.1", forHTTPHeaderField: "User-Agent")
        for (field, value) in download.headers { request.setValue(value, forHTTPHeaderField: field) }
        let (tempFile, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw InstallError("Download failed (HTTP \(http.statusCode)).")
        }
        let name = response.suggestedFilename ?? url.lastPathComponent
        let destination = dir.appendingPathComponent(name.isEmpty ? "update" : name)
        try FileManager.default.moveItem(at: tempFile, to: destination)
        return destination
    }

    // MARK: Verification

    private func verifyChecksum(of archive: URL) throws {
        guard let checksum = download.checksum else { return } // Code signature check still applies.
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        let matches: Bool
        switch checksum {
        case .sha256Hex(let expected):
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            matches = actual == expected.lowercased()
        case .sha512Base64(let expected):
            matches = Data(SHA512.hash(data: data)).base64EncodedString() == expected
        }
        guard matches else {
            throw InstallError("The download doesn't match its published checksum. It may be corrupt or tampered with.")
        }
    }

    private func verifyEdSignature(of archive: URL) throws {
        guard case .sparkleEdDSA(let signatureString) = signatureCheck,
              let keyString = app.sparklePublicEDKey else { return } // Code signature check still applies.
        guard let signatureString else {
            throw InstallError("The update isn't signed, but \(app.name) requires signed updates.")
        }
        guard let keyData = Data(base64Encoded: keyString),
              let signature = Data(base64Encoded: signatureString),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw InstallError("The update's signature couldn't be read.")
        }
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        guard key.isValidSignature(signature, for: data) else {
            throw InstallError("The update's signature is invalid. It may have been tampered with.")
        }
    }

    private func verifyCodeSignature(of newApp: URL) throws {
        let newCode = try staticCode(for: newApp)
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(newCode, flags, nil) == errSecSuccess else {
            throw InstallError("The update's code signature is invalid.")
        }
        guard Self.bundleID(of: newApp) == app.bundleID else {
            throw InstallError("The downloaded app isn't \(app.name).")
        }
        // If the installed app comes from a known developer, the update must too.
        if let oldTeam = teamID(of: app.url), teamID(of: newApp) != oldTeam {
            throw InstallError("The update is signed by a different developer than \(app.name).")
        }
    }

    private func staticCode(for url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw InstallError("Couldn't read the code signature of \(url.lastPathComponent).")
        }
        return code
    }

    private func teamID(of url: URL) -> String? {
        guard let code = try? staticCode(for: url) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: Archive handling

    private func archiveKind(of file: URL) throws -> ArchiveKind {
        let name = file.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".dmg") { return .dmg }
        if name.hasSuffix(".pkg") || name.hasSuffix(".mpkg") { return .pkg }
        if [".tar", ".tgz", ".tar.gz", ".tbz", ".tar.bz2", ".tar.xz", ".txz"].contains(where: name.hasSuffix) { return .tar }

        // No useful extension (e.g. a download URL with a query): sniff the header.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        if magic.starts(with: [0x50, 0x4B]) { return .zip }                // "PK"
        if magic.starts(with: Array("xar!".utf8)) { return .pkg }
        if magic.starts(with: [0x1F, 0x8B]) || magic.starts(with: Array("BZh".utf8)) { return .tar }
        return .dmg
    }

    private func findApp(in dir: URL, depth: Int) -> URL? {
        guard depth > 0,
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        let apps = items.filter { $0.pathExtension == "app" }
        if let match = apps.first(where: { Self.bundleID(of: $0) == app.bundleID }) { return match }
        for item in items where item.pathExtension != "app" && item.hasDirectoryPath {
            if let match = findApp(in: item, depth: depth - 1) { return match }
        }
        return nil
    }

    private static func bundleID(of url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    // MARK: Replacement

    /// Moves the old bundle aside, copies the new one into place, and restores the old one on failure.
    /// Falls back to an administrator prompt when the app isn't writable by the current user.
    private func replace(_ oldApp: URL, with newApp: URL, backupDir: URL) async throws {
        let backup = backupDir.appendingPathComponent("previous-\(oldApp.lastPathComponent)")
        let script = """
        set -e
        /bin/mv "$1" "$3"
        if /usr/bin/ditto "$2" "$1"; then
            /bin/rm -rf "$3"
        else
            /bin/rm -rf "$1"; /bin/mv "$3" "$1"; exit 1
        fi
        """
        let args = [oldApp.path, newApp.path, backup.path]

        let result = try await Shell.run("/bin/sh", ["-c", script, "sh"] + args)
        if result.succeeded { return }

        if result.stderr.contains("Operation not permitted") {
            throw InstallError("""
                macOS blocked FastUpdater from modifying \(app.name). Allow it under \
                System Settings › Privacy & Security › App Management, then try again.
                """)
        }
        guard result.stderr.contains("Permission denied") else {
            throw ShellError(command: "install", result: result)
        }

        // Pass paths as arguments and quote them in AppleScript so no path can inject shell code.
        let appleScript = """
        on run argv
            do shell script "/bin/sh -c " & quoted form of (item 1 of argv) & " sh " & ¬
                quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv) & " " & ¬
                quoted form of (item 4 of argv) with administrator privileges
        end run
        """
        let admin = try await Shell.run("/usr/bin/osascript", ["-e", appleScript, script] + args)
        guard admin.succeeded else {
            if admin.stderr.contains("-128") { throw InstallError("Cancelled.") }
            throw ShellError(command: "install", result: admin)
        }
    }
}
