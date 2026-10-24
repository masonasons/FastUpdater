# FastUpdater

A native macOS app (AppKit) that checks the apps on your Mac for updates, lets you choose which ones to update, and installs them.

## Update sources

Each app is checked by exactly one source, in this order:

| Source | Which apps | How updates are installed |
| --- | --- | --- |
| App Store | Mac App Store apps, and iPhone/iPad apps on Apple silicon | `mas upgrade` for Mac apps (falls back to opening the App Store); iPhone/iPad apps open their App Store page |
| Homebrew | Apps installed with `brew install --cask` | `brew upgrade --cask` |
| Sparkle | Apps with a Sparkle appcast (`SUFeedURL`) | Direct download, verified with the app's EdDSA key |
| Electron | Apps using electron-builder's updater (`app-update.yml`) | Direct download, verified by SHA-512 |
| Homebrew Catalog | Everything else Homebrew's public cask catalog knows | Direct download from the vendor, verified by SHA-256 when published |
| Apple (opt-in) | macOS, Safari, Command Line Tools (Updates › Include macOS & Safari Updates) | `softwareupdate`; macOS itself is handed to System Settings |

Every directly downloaded update must be validly code-signed by the same developer as the installed copy before it replaces anything, and the old version is restored if the swap fails.

## Using it

- FastUpdater checks on launch. **⌘R** checks again, **⌘U** updates the checked apps.
- **Space** checks or unchecks the highlighted app. The Status column says "Will update" or "Won't update" for each one.
- Apps that are open are quit and reopened after you confirm. Apps that ignore a normal quit can be force quit, again only if you confirm.
- Built with VoiceOver in mind: each checkbox is named after its app, and progress is announced.

If macOS blocks an update, allow FastUpdater under **System Settings › Privacy & Security › App Management**.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -scheme FastUpdater -derivedDataPath build build
open build/Build/Products/Debug/FastUpdater.app
```

Run the tests with `xcodebuild -scheme FastUpdater -derivedDataPath build test`.
