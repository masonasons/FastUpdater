import AppKit

/// Builds the menu bar in code. Window-specific items target the first responder,
/// so they're handled by `MainWindowController` through the responder chain.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(updatesMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(windowMenu()))
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "FastUpdater")
        menu.addItem(withTitle: "About FastUpdater",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide FastUpdater", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit FastUpdater", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private static func updatesMenu() -> NSMenu {
        let menu = NSMenu(title: "Updates")
        menu.addItem(withTitle: "Check for Updates",
                     action: #selector(MainWindowController.checkForUpdates(_:)), keyEquivalent: "r")
        menu.addItem(withTitle: "Update Checked Apps",
                     action: #selector(MainWindowController.updateChecked(_:)), keyEquivalent: "u")
        menu.addItem(.separator())
        let checkAll = menu.addItem(withTitle: "Check All",
                                    action: #selector(MainWindowController.checkAll(_:)), keyEquivalent: "a")
        checkAll.keyEquivalentModifierMask = [.command, .option]
        let uncheckAll = menu.addItem(withTitle: "Uncheck All",
                                      action: #selector(MainWindowController.uncheckAll(_:)), keyEquivalent: "a")
        uncheckAll.keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Include macOS & Safari Updates",
                     action: #selector(MainWindowController.toggleSystemUpdates(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show in Finder",
                     action: #selector(MainWindowController.revealInFinder(_:)), keyEquivalent: "")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return menu
    }
}
