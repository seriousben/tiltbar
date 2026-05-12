import Cocoa

extension Notification.Name {
    static let colorPreferencesDidChange = Notification.Name("ColorPreferencesDidChange")
}

class ColorPreferencesStore {
    private let themeKey = "statusColorTheme"
    private func overrideKey(for role: StatusColorRole) -> String {
        "statusColorOverride.\(role.rawValue)"
    }

    var themeID: String {
        get { UserDefaults.standard.string(forKey: themeKey) ?? ColorTheme.default.id }
        set {
            UserDefaults.standard.set(newValue, forKey: themeKey)
            notify()
        }
    }

    var theme: ColorTheme { ColorTheme.theme(id: themeID) }

    func override(for role: StatusColorRole) -> NSColor? {
        guard let hex = UserDefaults.standard.string(forKey: overrideKey(for: role)) else {
            return nil
        }
        return NSColor(hex: hex)
    }

    func setOverride(_ color: NSColor?, for role: StatusColorRole) {
        let key = overrideKey(for: role)
        if let color = color, let hex = color.hexString {
            UserDefaults.standard.set(hex, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        notify()
    }

    func color(for role: StatusColorRole) -> NSColor {
        override(for: role) ?? theme.color(for: role)
    }

    func resetOverrides() {
        for role in StatusColorRole.allCases {
            UserDefaults.standard.removeObject(forKey: overrideKey(for: role))
        }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: .colorPreferencesDidChange, object: self)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else {
            return nil
        }
        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((value >> 16) & 0xFF) / 255.0
            g = CGFloat((value >> 8) & 0xFF) / 255.0
            b = CGFloat(value & 0xFF) / 255.0
            a = 1.0
        } else {
            r = CGFloat((value >> 24) & 0xFF) / 255.0
            g = CGFloat((value >> 16) & 0xFF) / 255.0
            b = CGFloat((value >> 8) & 0xFF) / 255.0
            a = CGFloat(value & 0xFF) / 255.0
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        let a = Int(round(c.alphaComponent * 255))
        if a == 255 {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        return String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}
