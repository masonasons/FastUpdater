import AppKit

/// A table where Space toggles the checkbox of the selected rows,
/// so the list can be worked entirely from the keyboard.
final class UpdatesTableView: NSTableView {
    var onToggleSelectedRows: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           !selectedRowIndexes.isEmpty {
            onToggleSelectedRows?()
        } else {
            super.keyDown(with: event)
        }
    }
}
