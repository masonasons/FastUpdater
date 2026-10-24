import AppKit

/// The App column: a checkbox, the app's icon, and its name.
///
/// To accessibility it's a single checkbox named after the app ("Firefox, checkbox,
/// checked"), and clicking the name toggles it like a checkbox's own title would.
final class AppCheckCell: NSTableCellView {
    let checkbox: NSButton
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, target: AnyObject, action: Selector) {
        checkbox = NSButton(checkboxWithTitle: "", target: target, action: action)
        super.init(frame: .zero)
        self.identifier = identifier

        icon.setAccessibilityElement(false)
        nameLabel.setAccessibilityElement(false)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(nameClicked)))

        for view in [checkbox, icon, nameLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = nameLabel

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, icon image: NSImage, checked: Bool, enabled: Bool, textColor: NSColor) {
        checkbox.state = checked ? .on : .off
        checkbox.isEnabled = enabled
        checkbox.setAccessibilityLabel(name)
        icon.image = image
        icon.alphaValue = textColor == .labelColor ? 1 : 0.5
        nameLabel.stringValue = name
        nameLabel.textColor = textColor
    }

    @objc private func nameClicked() {
        if checkbox.isEnabled { checkbox.performClick(nil) }
    }
}
