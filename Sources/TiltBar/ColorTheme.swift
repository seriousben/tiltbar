import Cocoa

enum StatusColorRole: String, CaseIterable {
    case error
    case warning
    case inProgress
    case success

    var displayName: String {
        switch self {
        case .error: return "Errors"
        case .warning: return "Warnings"
        case .inProgress: return "In Progress"
        case .success: return "Success"
        }
    }
}

struct ColorTheme {
    let id: String
    let displayName: String
    let colors: [StatusColorRole: NSColor]

    func color(for role: StatusColorRole) -> NSColor {
        colors[role] ?? .labelColor
    }

    static let `default` = ColorTheme(
        id: "default",
        displayName: "Default",
        colors: [
            .error: .red,
            .warning: .yellow,
            .inProgress: .gray,
            .success: .green,
        ]
    )

    static let system = ColorTheme(
        id: "system",
        displayName: "System",
        colors: [
            .error: .systemRed,
            .warning: .systemYellow,
            .inProgress: .systemGray,
            .success: .systemGreen,
        ]
    )

    static let highContrast = ColorTheme(
        id: "highContrast",
        displayName: "High Contrast",
        colors: [
            .error: NSColor(srgbRed: 0.85, green: 0.10, blue: 0.10, alpha: 1.0),
            .warning: NSColor(srgbRed: 0.95, green: 0.55, blue: 0.00, alpha: 1.0),
            .inProgress: NSColor(srgbRed: 0.35, green: 0.35, blue: 0.40, alpha: 1.0),
            .success: NSColor(srgbRed: 0.10, green: 0.55, blue: 0.20, alpha: 1.0),
        ]
    )

    static let all: [ColorTheme] = [.default, .system, .highContrast]

    static func theme(id: String) -> ColorTheme {
        all.first { $0.id == id } ?? .default
    }
}
