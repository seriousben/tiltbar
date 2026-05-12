import Cocoa

class PreferencesWindowController: NSWindowController {
    private let store: ColorPreferencesStore
    private var themePopup: NSPopUpButton!
    private var colorWells: [StatusColorRole: NSColorWell] = [:]
    private var clearButtons: [StatusColorRole: NSButton] = [:]
    private var previewField: NSTextField!

    init(store: ColorPreferencesStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TiltBar Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
        refreshFromStore()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(prefsChangedExternally),
            name: .colorPreferencesDidChange,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildUI() {
        guard let window = window else { return }
        let content = NSView(frame: window.contentLayoutRect)
        content.translatesAutoresizingMaskIntoConstraints = false

        let themeLabel = label("Theme:")
        themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for theme in ColorTheme.all {
            themePopup.addItem(withTitle: theme.displayName)
            themePopup.lastItem?.representedObject = theme.id
        }
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        themePopup.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let themeRow = NSStackView(views: [themeLabel, themePopup])
        themeRow.orientation = .horizontal
        themeRow.spacing = 8
        stack.addArrangedSubview(themeRow)

        stack.addArrangedSubview(separator())

        for role in StatusColorRole.allCases {
            let rowLabel = label(role.displayName)
            rowLabel.translatesAutoresizingMaskIntoConstraints = false
            rowLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true

            let well = NSColorWell()
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
            well.target = self
            well.action = #selector(colorWellChanged(_:))
            well.identifier = NSUserInterfaceItemIdentifier(role.rawValue)
            colorWells[role] = well

            let clear = NSButton(title: "Clear", target: self, action: #selector(clearOverride(_:)))
            clear.bezelStyle = .rounded
            clear.controlSize = .small
            clear.identifier = NSUserInterfaceItemIdentifier(role.rawValue)
            clearButtons[role] = clear

            let row = NSStackView(views: [rowLabel, well, clear])
            row.orientation = .horizontal
            row.spacing = 8
            stack.addArrangedSubview(row)
        }

        stack.addArrangedSubview(separator())

        let previewLabel = label("Preview:")
        previewField = NSTextField(labelWithString: "")
        previewField.font = NSFont.menuBarFont(ofSize: 0)
        let previewRow = NSStackView(views: [previewLabel, previewField])
        previewRow.orientation = .horizontal
        previewRow.spacing = 8
        stack.addArrangedSubview(previewRow)

        let resetAll = NSButton(title: "Reset All Overrides", target: self, action: #selector(resetAll(_:)))
        resetAll.bezelStyle = .rounded
        stack.addArrangedSubview(resetAll)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
    }

    private func label(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        return f
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        return b
    }

    private func refreshFromStore() {
        let currentID = store.themeID
        for i in 0..<themePopup.numberOfItems {
            if let id = themePopup.item(at: i)?.representedObject as? String, id == currentID {
                themePopup.selectItem(at: i)
                break
            }
        }
        for role in StatusColorRole.allCases {
            colorWells[role]?.color = store.color(for: role)
            clearButtons[role]?.isEnabled = store.override(for: role) != nil
        }
        refreshPreview()
    }

    private func refreshPreview() {
        let attributed = NSMutableAttributedString()
        let samples: [(StatusColorRole, String)] = [
            (.error, "3"),
            (.warning, "2"),
            (.inProgress, "5"),
            (.success, "12"),
        ]
        for (i, (role, text)) in samples.enumerated() {
            if i > 0 { attributed.append(NSAttributedString(string: " ")) }
            attributed.append(NSAttributedString(
                string: text,
                attributes: [.foregroundColor: store.color(for: role)]
            ))
        }
        previewField.attributedStringValue = attributed
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        store.themeID = id
    }

    @objc private func colorWellChanged(_ sender: NSColorWell) {
        guard let id = sender.identifier?.rawValue,
              let role = StatusColorRole(rawValue: id) else { return }
        store.setOverride(sender.color, for: role)
    }

    @objc private func clearOverride(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
              let role = StatusColorRole(rawValue: id) else { return }
        store.setOverride(nil, for: role)
    }

    @objc private func resetAll(_ sender: NSButton) {
        store.resetOverrides()
    }

    @objc private func prefsChangedExternally() {
        refreshFromStore()
    }
}
