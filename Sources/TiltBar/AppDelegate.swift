import Cocoa

/// AppDelegate manages the status bar app lifecycle
///
/// ## Status Bar Display:
/// - Uses dynamic Tilt logo icons (green/gray/red) based on resource health
/// - When all resources are green: Shows just the logo
/// - When issues present: Shows logo + status counts (e.g., "⚪️2 🟢5 🔴1")
///
/// ## Icon Selection:
/// - Red: Any resources with errors
/// - Gray: Resources building, warnings, or disconnected
/// - Green: All resources successful
///
/// ## Menu Items:
/// - Status display (read-only)
/// - Open Tilt in Browser
/// - Reconnect Now (hidden when connected)
/// - Quit
class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    /// The status bar item that appears in the menu bar
    /// We keep a strong reference to prevent it from being deallocated
    private var statusItem: NSStatusItem?

    /// The Tilt API client
    private let tiltClient = TiltClient()

    /// Current resource status (for display)
    private var currentStatus = ResourceStatus()

    /// Current connection state
    private var currentConnectionState: ConnectionState = .disconnected

    /// Cached Tilt icons
    private var grayIcon: NSImage?
    private var greenIcon: NSImage?
    private var redIcon: NSImage?

    /// Track the currently displayed icon to avoid animating when unchanged
    private var currentIcon: NSImage?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load Tilt icons from Resources
        loadIcons()

        // Create a status bar item with variable length
        // NSStatusBar.system is the main system status bar
        // The length will adjust based on our title/image
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Set up the status bar button
        if let button = statusItem?.button {
            // Set initial icon and text
            button.image = grayIcon
            button.title = " Starting..."
        }

        // Create and set the menu
        setupMenu()

        // Set up Tilt client callbacks
        tiltClient.onStatusUpdate = { [weak self] status in
            self?.handleStatusUpdate(status)
        }

        tiltClient.onConnectionStateChange = { [weak self] state in
            self?.handleConnectionStateChange(state)
        }

        // Start watching Tilt
        tiltClient.start()
    }

    /// Load Tilt icons from the Resources directory
    private func loadIcons() {
        // Get the path to the Resources directory
        // Since we're using Process, we need to find the Resources relative to the executable
        let executablePath = Bundle.main.executablePath ?? ""
        let executableDir = (executablePath as NSString).deletingLastPathComponent
        let resourcesPath = (executableDir as NSString).appendingPathComponent("Resources")

        // Try to load icons from the Resources directory
        let grayPath = (resourcesPath as NSString).appendingPathComponent("tilt-gray.png")
        let greenPath = (resourcesPath as NSString).appendingPathComponent("tilt-icon.png")  // Green icon
        let redPath = (resourcesPath as NSString).appendingPathComponent("tilt-red.png")

        grayIcon = NSImage(contentsOfFile: grayPath)
        greenIcon = NSImage(contentsOfFile: greenPath)
        redIcon = NSImage(contentsOfFile: redPath)

        // Set images to template rendering mode for better menu bar integration
        grayIcon?.isTemplate = false  // Keep colors
        greenIcon?.isTemplate = false
        redIcon?.isTemplate = false

        // Resize icons to fit menu bar (typically 16x16 or 18x18)
        let iconSize = NSSize(width: 18, height: 18)
        grayIcon?.size = iconSize
        greenIcon?.size = iconSize
        redIcon?.size = iconSize
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Clean up when the app is closing
        tiltClient.stop()
    }

    // MARK: - Menu Setup

    private func setupMenu() {
        let menu = NSMenu()

        // Status display (disabled item, just for showing info)
        let statusMenuItem = NSMenuItem(
            title: "Status: Connecting...",
            action: nil,
            keyEquivalent: ""
        )
        statusMenuItem.isEnabled = false
        statusMenuItem.tag = 100 // Tag to find it later
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Open in Browser
        let openMenuItem = NSMenuItem(
            title: "Open Tilt in Browser",
            action: #selector(openInBrowser),
            keyEquivalent: "o"
        )
        openMenuItem.target = self
        menu.addItem(openMenuItem)

        // Reconnect Now
        let reconnectMenuItem = NSMenuItem(
            title: "Reconnect Now",
            action: #selector(reconnectNow),
            keyEquivalent: "r"
        )
        reconnectMenuItem.target = self
        reconnectMenuItem.tag = 101 // Tag to find it later
        menu.addItem(reconnectMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitMenuItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        statusItem?.menu = menu
    }

    // MARK: - Status Updates

    private func handleStatusUpdate(_ status: ResourceStatus) {
        currentStatus = status
        updateDisplay()
    }

    private func handleConnectionStateChange(_ state: ConnectionState) {
        currentConnectionState = state
        updateDisplay()
    }

    /// Animates the icon transition with a smooth fade effect
    private func setIconWithAnimation(_ newIcon: NSImage?, button: NSStatusBarButton) {
        // Skip animation if icon hasn't changed
        if currentIcon === newIcon {
            return
        }

        // Store the new icon
        currentIcon = newIcon

        // Perform fade animation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.animator().alphaValue = 0.0
        }, completionHandler: {
            button.image = newIcon
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.animator().alphaValue = 1.0
            })
        })
    }

    private func updateDisplay() {
        // Update the status bar button icon and text
        if let button = statusItem?.button {
            // Choose the appropriate icon and animate the transition
            let newIcon = chooseIcon()
            setIconWithAnimation(newIcon, button: button)

            // Set the title text
            let text = buildStatusBarText()
            button.title = text.isEmpty ? "" : " \(text)"  // Add space before text for padding
        }

        // Update the status menu item
        if let menu = statusItem?.menu,
           let statusMenuItem = menu.item(withTag: 100) {
            statusMenuItem.title = buildStatusText()
        }

        // Update reconnect button visibility
        if let menu = statusItem?.menu,
           let reconnectMenuItem = menu.item(withTag: 101) {
            // Only show reconnect when disconnected or server down
            reconnectMenuItem.isHidden = currentConnectionState == .connected || currentConnectionState == .connecting
        }
    }

    /// Choose the appropriate Tilt icon based on current status
    /// Red logo: if errors > 0
    /// Yellow/orange logo: if warnings > 0 but no errors (use gray as proxy for yellow)
    /// Green logo: otherwise (all success)
    private func chooseIcon() -> NSImage? {
        // If not connected, show gray icon
        if currentConnectionState != .connected {
            return grayIcon
        }

        // If there are errors, show red logo
        if currentStatus.error > 0 {
            return redIcon
        }

        // If there are warnings (but no errors), show gray logo (as proxy for yellow/orange)
        if currentStatus.warning > 0 {
            return grayIcon
        }

        // Everything is green!
        return greenIcon
    }

    /// Build the text to show in the status bar
    /// Format: [red_count/][yellow_count/]green_count/total
    /// Red and yellow counts are hidden if zero
    private func buildStatusBarText() -> String {
        switch currentConnectionState {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .serverDown:
            return "Server Down"
        case .connected:
            // If everything is green/successful, show no text (just icon)
            if currentStatus.error == 0 && currentStatus.warning == 0 && currentStatus.inProgress == 0 && currentStatus.success > 0 {
                return ""
            }

            if currentStatus.total == 0 {
                return "No Resources"
            }

            // Build format: [red/][yellow/]green/total
            // Use NSAttributedString for colored text
            var parts: [String] = []

            // Red count (errors) - only show if > 0
            if currentStatus.error > 0 {
                parts.append("\(currentStatus.error)")
            }

            // Yellow count (warnings) - only show if > 0
            if currentStatus.warning > 0 {
                parts.append("\(currentStatus.warning)")
            }

            // Green count (success)
            parts.append("\(currentStatus.success)")

            // Total count
            parts.append("\(currentStatus.total)")

            return parts.joined(separator: "/")
        }
    }

    /// Build the text to show in the status menu item
    private func buildStatusText() -> String {
        let connectionText = currentConnectionState.displayText

        if currentConnectionState == .connected {
            return "Status: \(connectionText) - \(currentStatus.summary)"
        } else {
            return "Status: \(connectionText)"
        }
    }

    // MARK: - Menu Actions

    @objc private func openInBrowser() {
        // Open the default browser to the Tilt URL
        if let url = URL(string: "http://localhost:10350") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func reconnectNow() {
        tiltClient.reconnectNow()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
