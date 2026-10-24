import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSToolbarItemValidation {

    private enum Column: String, CaseIterable {
        case app, installed, available, source, status

        var title: String {
            switch self {
            case .app: return "App"
            case .installed: return "Installed"
            case .available: return "Available"
            case .source: return "Source"
            case .status: return "Status"
            }
        }

        var width: CGFloat {
            switch self {
            case .app: return 240
            case .installed, .available: return 110
            case .source: return 90
            case .status: return 220
            }
        }
    }

    private static let includeSystemUpdatesKey = "IncludeSystemUpdates"
    private var includeSystemUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: Self.includeSystemUpdatesKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.includeSystemUpdatesKey) }
    }

    private static let checkItemID = NSToolbarItem.Identifier("check")
    private static let updateItemID = NSToolbarItem.Identifier("update")

    private var rows: [UpdateRow] = []
    private var isChecking = false
    private var isInstalling = false

    private let tableView = UpdatesTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let notesView = NSTextView()
    private var splitView: NSSplitView?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FastUpdater"
        window.minSize = NSSize(width: 640, height: 400)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        super.init(window: window)
        window.delegate = self
        buildToolbar()
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Layout

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func buildContent() {
        summaryLabel.font = .preferredFont(forTextStyle: .title3)
        summaryLabel.setAccessibilityRole(.staticText)
        summaryLabel.lineBreakMode = .byTruncatingTail

        // Table
        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column == .app ? 140 : 60
            tableColumn.resizingMask = [.userResizingMask, .autoresizingMask]
            tableView.addTableColumn(tableColumn)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.rowHeight = 28
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.setAccessibilityLabel("Available updates")
        tableView.onToggleSelectedRows = { [weak self] in self?.toggleSelectedRows() }

        let tableScroll = NSScrollView()
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true

        // Release notes
        notesView.isEditable = false
        notesView.isSelectable = true
        notesView.textContainerInset = NSSize(width: 8, height: 8)
        notesView.font = .preferredFont(forTextStyle: .body)
        notesView.isAutomaticLinkDetectionEnabled = true
        notesView.setAccessibilityLabel("Release notes")
        notesView.autoresizingMask = [.width]
        notesView.isVerticallyResizable = true
        notesView.textContainer?.widthTracksTextView = true

        let notesScroll = NSScrollView()
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.autosaveName = "MainSplit"
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(notesScroll)
        // When the window grows, the list gets the extra height, not the release notes.
        split.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)

        // Status bar
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel("Working")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusBar = NSStackView(views: [spinner, statusLabel])
        statusBar.orientation = .horizontal
        statusBar.spacing = 6
        statusBar.setHuggingPriority(.required, for: .vertical)

        guard let content = window?.contentView else { return }
        for view in [summaryLabel, split, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),

            split.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            statusBar.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 8),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusBar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            notesScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        window?.initialFirstResponder = tableView

        splitView = split
        showNotes(for: nil)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Give the table most of the height on first launch; later launches restore the saved split.
        if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplit") == nil, let splitView {
            window?.layoutIfNeeded()
            splitView.setPosition(splitView.bounds.height * 0.65, ofDividerAt: 0)
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.checkItemID, .flexibleSpace, Self.updateItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        switch id {
        case Self.checkItemID:
            item.label = "Check for Updates"
            item.toolTip = "Check all apps for updates (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Check for Updates")
            item.action = #selector(checkForUpdates(_:))
        case Self.updateItemID:
            item.label = "Update Checked"
            item.toolTip = "Install updates for the checked apps (⌘U)"
            item.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Update Checked")
            item.action = #selector(updateChecked(_:))
        default:
            return nil
        }
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier == Self.updateItemID { item.label = updateActionTitle }
        return validate(item.action)
    }

    /// "Update 3 Apps", so it's always clear how many updates the button will start.
    private var updateActionTitle: String {
        switch checkedPendingRows.count {
        case 0: return "Update Checked Apps"
        case 1: return "Update 1 App"
        case let n: return "Update \(n) Apps"
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSystemUpdates(_:)) {
            menuItem.state = includeSystemUpdates ? .on : .off
        }
        if menuItem.action == #selector(updateChecked(_:)) {
            menuItem.title = updateActionTitle
        }
        return validate(menuItem.action)
    }

    private func validate(_ action: Selector?) -> Bool {
        let busy = isChecking || isInstalling
        switch action {
        case #selector(checkForUpdates(_:)), #selector(toggleSystemUpdates(_:)): return !busy
        case #selector(updateChecked(_:)): return !busy && !checkedPendingRows.isEmpty
        case #selector(checkAll(_:)), #selector(uncheckAll(_:)): return !isInstalling && !rows.isEmpty
        case #selector(revealInFinder(_:)): return !targetRows.isEmpty
        default: return true
        }
    }

    // MARK: Actions

    @objc func checkForUpdates(_ sender: Any?) {
        guard !isChecking, !isInstalling else { return }
        isChecking = true
        rows = []
        tableView.reloadData()
        showNotes(for: nil)
        summaryLabel.stringValue = "Checking for updates…"
        setStatus(includeSystemUpdates
                  ? "Checking apps and Apple Software Update (this takes a little longer)…"
                  : "Scanning Applications folders and checking update sources…", busy: true)
        announce("Checking for updates")

        Task {
            var checker = UpdateChecker()
            checker.includeSystemUpdates = includeSystemUpdates
            let report = await checker.check()
            rows = report.updates.map(UpdateRow.init)
            isChecking = false
            tableView.reloadData()
            if !rows.isEmpty { tableView.selectRowIndexes([0], byExtendingSelection: false) }
            refreshSummary(scanned: report.scannedCount)

            let errors = report.errors.joined(separator: " · ")
            setStatus(errors.isEmpty ? "Checked \(report.scannedCount) apps." : errors, busy: false)
            announce(summaryLabel.stringValue)
            window?.toolbar?.validateVisibleItems()
        }
    }

    @objc func updateChecked(_ sender: Any?) {
        let pending = checkedPendingRows
        guard !pending.isEmpty, !isChecking, !isInstalling else { return }

        // Warn before quitting anything. App Store and Apple updates manage running apps themselves.
        let running = pending.filter { row in
            switch row.update.source {
            case .appStore, .systemUpdate: return false
            default: break
            }
            return !UpdateInstaller.runningInstances(of: row.update.app).isEmpty
        }
        if !running.isEmpty {
            let alert = NSAlert()
            alert.messageText = running.count == 1
                ? "\(running[0].name) is open"
                : "\(running.count) apps are open"
            alert.informativeText = "These apps will be quit, updated, and reopened: "
                + running.map(\.name).joined(separator: ", ")
                + ". Unsaved changes may be lost."
            alert.addButton(withTitle: "Quit and Update")
            alert.addButton(withTitle: "Cancel")
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.install(pending) }
            }
        } else {
            install(pending)
        }
    }

    @objc func toggleSystemUpdates(_ sender: Any?) {
        includeSystemUpdates.toggle()
        announce(includeSystemUpdates ? "macOS and Safari updates included" : "macOS and Safari updates excluded")
        checkForUpdates(nil)
    }

    @objc func checkAll(_ sender: Any?) {
        setChecked(true, rows: rows)
        announce("All \(checkedPendingRows.count) apps will update.")
    }

    @objc func uncheckAll(_ sender: Any?) {
        setChecked(false, rows: rows)
        announce("No apps will update.")
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting(targetRows.map(\.update.app.url))
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        let index = tableView.row(for: sender)
        guard rows.indices.contains(index) else { return }
        setChecked(sender.state == .on, rows: [rows[index]])
        announceChoice(for: rows[index])
    }

    /// Space bar on the highlighted row.
    private func toggleSelectedRows() {
        guard rows.indices.contains(tableView.selectedRow), !isInstalling else { return }
        let row = rows[tableView.selectedRow]
        guard !row.status.isFinished else { return }
        setChecked(!row.isChecked, rows: [row])
        announceChoice(for: row)
    }

    private func announceChoice(for row: UpdateRow) {
        let total = rows.filter { !$0.status.isFinished }.count
        announce("\(row.name) \(row.isChecked ? "will update" : "won't update"). "
                 + "\(checkedPendingRows.count) of \(total) will update.")
    }

    private func setChecked(_ value: Bool, rows targets: [UpdateRow]) {
        for row in targets where !row.status.isFinished { row.isChecked = value }
        refresh(targets)
        refreshSummary(scanned: nil)
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: Installing

    private func install(_ pending: [UpdateRow]) {
        isInstalling = true
        window?.toolbar?.validateVisibleItems()
        pending.forEach { $0.status = .waiting }
        refresh(rows)  // Also disables every checkbox while installing.

        Task {
            var installer = UpdateInstaller()
            installer.confirmForceQuit = { name in await self.askToForceQuit(name) }
            var succeeded = 0, failed = 0

            for (index, row) in pending.enumerated() {
                setStatus("Updating \(row.name) (\(index + 1) of \(pending.count))…", busy: true)
                row.status = .working("Starting…")
                refresh([row])

                do {
                    let outcome = try await installer.install(row.update) { step in
                        Task { @MainActor in
                            guard case .working = row.status else { return }
                            row.status = .working(step)
                            self.refresh([row])
                        }
                    }
                    switch outcome {
                    case .installed:
                        row.status = .installed
                        announce("\(row.name) updated to \(row.update.newVersion)")
                    case .handedOff(let message):
                        row.status = .handedOff(message)
                        announce("\(row.name): \(message)")
                    }
                    row.isChecked = false
                    succeeded += 1
                } catch {
                    row.status = .failed(error.localizedDescription)
                    announce("\(row.name) failed to update")
                    failed += 1
                }
                refresh([row])
            }

            isInstalling = false
            refresh(rows)
            refreshSummary(scanned: nil)
            var summary = "\(succeeded) of \(pending.count) update\(pending.count == 1 ? "" : "s") done"
            if failed > 0 { summary += ", \(failed) failed. Select a failed app to see why" }
            setStatus(summary + ".", busy: false)
            announce(summary)
            window?.toolbar?.validateVisibleItems()
            showNotes(for: tableView.selectedRow >= 0 ? rows[tableView.selectedRow] : nil)
        }
    }

    private func askToForceQuit(_ name: String) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = "\(name) didn't quit"
        alert.informativeText = "Force quit \(name) so it can be updated? Any unsaved changes in \(name) will be lost."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Skip \(name)")
        announce("\(name) didn't quit. Force quit it?")
        let response = await alert.beginSheetModal(for: window)
        return response == .alertFirstButtonReturn
    }

    // MARK: Helpers

    private var checkedPendingRows: [UpdateRow] {
        rows.filter { $0.isChecked && !$0.status.isFinished }
    }

    /// The clicked row (for context menus) or the selection.
    private var targetRows: [UpdateRow] {
        tableView.selectedRowIndexes.map { rows[$0] }
    }

    /// Updates the visible cells of these rows in place. Reloading would replace the views
    /// and knock VoiceOver or keyboard focus off the checkbox that was just toggled.
    private func refresh(_ targets: [UpdateRow]) {
        for target in targets {
            guard let index = rows.firstIndex(where: { $0 === target }) else { continue }
            for (columnIndex, column) in Column.allCases.enumerated() {
                guard let view = tableView.view(atColumn: columnIndex, row: index, makeIfNecessary: false) else { continue }
                configure(view, column: column, row: target)
            }
        }
    }

    private var lastScanned = 0

    private func refreshSummary(scanned: Int?) {
        if let scanned { lastScanned = scanned }
        let remaining = rows.filter { !$0.status.isFinished }.count
        switch remaining {
        case 0 where rows.isEmpty:
            summaryLabel.stringValue = "All \(lastScanned) apps are up to date."
        case 0:
            summaryLabel.stringValue = "All updates are done."
        default:
            let available = remaining == 1 ? "1 update available" : "\(remaining) updates available"
            summaryLabel.stringValue = "\(available) · \(checkedPendingRows.count) will update"
        }
    }

    private func setStatus(_ text: String, busy: Bool) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    /// Speaks a message through VoiceOver (no-op when VoiceOver is off).
    private func announce(_ message: String) {
        guard let window else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    // MARK: Release notes

    private func showNotes(for row: UpdateRow?) {
        guard let row else {
            notesView.textStorage?.setAttributedString(plain(
                rows.isEmpty ? "" : "Select an app to see its release notes."
            ))
            return
        }
        let update = row.update
        let content = NSMutableAttributedString()
        let header = "\(update.app.name) \(update.newVersion)\n"
        content.append(NSAttributedString(string: header, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .headline),
            .foregroundColor: NSColor.labelColor,
        ]))
        content.append(plain("Installed: \(update.app.displayVersion) · Source: \(update.sourceName)\n"))
        if case .failed(let message) = row.status {
            content.append(NSAttributedString(string: "\nUpdate failed: \(message)\n", attributes: [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.systemRed,
            ]))
        }
        content.append(plain("\n"))

        if let fetched = row.fetchedNotes {
            content.append(fetched)
        } else if let notes = update.releaseNotes, !notes.isEmpty {
            content.append(Self.render(notes))
        } else if let url = update.releaseNotesURL {
            if case .sparkle = update.source {
                content.append(plain("Loading release notes…"))
                fetchNotes(for: row, from: url)
            } else {
                content.append(NSAttributedString(string: url.absoluteString, attributes: [
                    .link: url, .font: NSFont.preferredFont(forTextStyle: .body),
                ]))
            }
        } else {
            content.append(plain("No release notes provided."))
        }
        notesView.textStorage?.setAttributedString(content)
    }

    private func fetchNotes(for row: UpdateRow, from url: URL) {
        Task {
            let rendered: NSAttributedString
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                rendered = Self.render(String(decoding: data, as: UTF8.self))
            } else {
                rendered = NSAttributedString(string: url.absoluteString, attributes: [
                    .link: url, .font: NSFont.preferredFont(forTextStyle: .body),
                ])
            }
            row.fetchedNotes = rendered
            if tableView.selectedRow >= 0, rows.indices.contains(tableView.selectedRow),
               rows[tableView.selectedRow] === row {
                showNotes(for: row)
            }
        }
    }

    private func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    /// Renders HTML release notes (or passes plain text through) in the system font and colors.
    private static func render(_ notes: String) -> NSAttributedString {
        let looksLikeHTML = notes.range(of: "<[a-zA-Z][^>]*>", options: .regularExpression) != nil
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        guard looksLikeHTML else {
            return NSAttributedString(string: notes, attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor])
        }
        let styled = """
        <style>body { font-family: -apple-system; font-size: \(bodyFont.pointSize)px; }</style>\(notes)
        """
        guard let html = try? NSMutableAttributedString(
            data: Data(styled.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else {
            return NSAttributedString(string: notes, attributes: [.font: bodyFont])
        }
        // Use dynamic colors so notes stay legible in Dark Mode.
        let whole = NSRange(location: 0, length: html.length)
        html.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        while html.string.hasSuffix("\n") {
            html.deleteCharacters(in: NSRange(location: html.length - 1, length: 1))
        }
        return html
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selected = tableView.selectedRow
        showNotes(for: rows.indices.contains(selected) ? rows[selected] : nil)
        window?.toolbar?.validateVisibleItems()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let view: NSView
        switch column {
        case .app:
            let id = NSUserInterfaceItemIdentifier("appCell")
            view = tableView.makeView(withIdentifier: id, owner: self) as? AppCheckCell
                ?? AppCheckCell(identifier: id, target: self, action: #selector(checkboxClicked(_:)))
        default:
            view = textCell("", in: tableView)
        }
        configure(view, column: column, row: rows[index])
        return view
    }

    /// Fills a cell from its row. Rows that won't update are dimmed throughout, and before
    /// installing the Status column spells out what will happen.
    private func configure(_ view: NSView, column: Column, row: UpdateRow) {
        let update = row.update
        let skipped = !row.isChecked && !row.status.isFinished
        let textColor: NSColor = skipped ? .secondaryLabelColor : .labelColor

        if let cell = view as? AppCheckCell {
            cell.configure(
                name: row.name,
                icon: NSWorkspace.shared.icon(forFile: update.app.url.path),
                checked: row.isChecked,
                enabled: !row.status.isFinished && !isInstalling,
                textColor: textColor
            )
            cell.toolTip = update.app.url.path
            return
        }
        guard let cell = view as? NSTableCellView, let field = cell.textField else { return }
        field.textColor = textColor
        cell.toolTip = nil

        switch column {
        case .app: break
        case .installed: field.stringValue = update.app.displayVersion
        case .available: field.stringValue = update.newVersion
        case .source: field.stringValue = update.sourceName
        case .status:
            if row.status == .idle {
                field.stringValue = row.isChecked ? "Will update" : "Won't update"
            } else {
                field.stringValue = row.status.text
                cell.toolTip = row.status.text
                if case .failed = row.status {
                    field.textColor = .systemRed
                } else if row.status.isFinished {
                    field.textColor = .systemGreen
                }
            }
        }
    }

    private func textCell(_ string: String, in tableView: NSTableView) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier("textCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = string
        cell.textField?.textColor = .labelColor
        cell.toolTip = nil
        return cell
    }
}
