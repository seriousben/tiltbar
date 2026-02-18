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
/// - View on GitHub
/// - Reconnect Now (hidden when connected)
/// - Development Mode (hidden unless Option key is held)
/// - Quit
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // MARK: - Properties

    /// App version read from Info.plist (updated automatically by release-please)
    /// Appends "-dev (hash)" suffix for development builds
    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        if isDevelopmentBuild {
            let suffix = gitCommitHash.isEmpty ? "dev" : "dev @\(gitCommitHash)"
            return "\(version)-\(suffix)"
        }
        return version
    }

    /// Clean version for release notes URL (without dev suffix)
    private var releaseVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// The status bar item that appears in the menu bar
    /// We keep a strong reference to prevent it from being deallocated
    private var statusItem: NSStatusItem?

    /// The Tilt API client
    private let tiltClient = TiltClient()

    /// Current resource status (for display)
    private var currentStatus = ResourceStatus()

    /// Current connection state
    private var currentConnectionState: ConnectionState = .disconnected

    /// Current list of recent failures
    private var currentFailures: [FailureInfo] = []

    /// Current list of in-progress resources
    private var currentInProgress: [InProgressInfo] = []



    /// Current list of pending resources (not actively building)
    private var currentPendingResources: [PendingResourceInfo] = []

    /// Cached Tilt icons
    private var grayIcon: NSImage?
    private var greenIcon: NSImage?
    private var redIcon: NSImage?
    private var yellowIcon: NSImage?

    /// Track the currently displayed icon to avoid animating when unchanged
    private var currentIcon: NSImage?

    // MARK: - Development Mode

    /// Development mode state
    private var developmentMode: DevelopmentMode = .live

    /// Timer for cycling through states in Cycle All States mode
    private var cycleTimer: Timer?

    /// Current index in the cycle sequence
    private var cycleIndex: Int = 0

    /// Timer for updating the retry countdown in the menu
    private var menuUpdateTimer: Timer?

    /// Simulated next retry time for dev mode
    private var devModeNextRetryTime: Date?

    /// Last displayed countdown value (to avoid flickering updates)
    private var lastDisplayedCountdown: Int?

    /// Available development mode test states
    private enum DevelopmentMode {
        case live
        case allSuccess
        case withWarnings
        case withErrors
        case inProgress
        case disconnected
        case cycleAllStates
    }

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
            // Set initial icon (gray, no text for connecting state)
            button.image = grayIcon
            currentIcon = grayIcon  // Track the initial icon
            button.attributedTitle = NSAttributedString(string: "")
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

        tiltClient.onFailuresUpdate = { [weak self] failures in
            self?.handleFailuresUpdate(failures)
        }

        tiltClient.onInProgressUpdate = { [weak self] inProgress in
            self?.handleInProgressUpdate(inProgress)
        }

        tiltClient.onPendingResourcesUpdate = { [weak self] pendingResources in
            self?.handlePendingResourcesUpdate(pendingResources)
        }

        // Start watching Tilt
        tiltClient.start()
    }

    /// Load Tilt icons from the Resources directory
    private func loadIcons() {
        // Determine the Resources directory path
        // For .app bundles: Use Bundle.main.resourcePath (Contents/Resources)
        // For local builds: Look for Resources next to the executable
        let resourcesPath: String

        // Check if we're running from a .app bundle by looking for Info.plist
        let executablePath = Bundle.main.executablePath ?? ""
        let executableDir = (executablePath as NSString).deletingLastPathComponent
        let contentsDir = (executableDir as NSString).deletingLastPathComponent
        let bundlePath = (contentsDir as NSString).deletingLastPathComponent
        let infoPlistPath = ((bundlePath as NSString).appendingPathComponent("Contents") as NSString).appendingPathComponent("Info.plist")

        if FileManager.default.fileExists(atPath: infoPlistPath), let bundleResourcePath = Bundle.main.resourcePath {
            // Running from .app bundle - use Bundle's resource path
            resourcesPath = bundleResourcePath
        } else {
            // Running from local build - look for Resources next to executable
            resourcesPath = (executableDir as NSString).appendingPathComponent("Resources")
        }

        // Try to load icons from the Resources directory
        let grayPath = (resourcesPath as NSString).appendingPathComponent("tilt-gray.png")
        let greenPath = (resourcesPath as NSString).appendingPathComponent("tilt-icon.png")  // Green icon
        let redPath = (resourcesPath as NSString).appendingPathComponent("tilt-red.png")

        grayIcon = NSImage(contentsOfFile: grayPath)
        greenIcon = NSImage(contentsOfFile: greenPath)
        redIcon = NSImage(contentsOfFile: redPath)

        // Create yellow icon by tinting the green icon
        if let green = greenIcon {
            yellowIcon = tintImage(green, with: NSColor.yellow)
        }

        // Set images to template rendering mode for better menu bar integration
        grayIcon?.isTemplate = false  // Keep colors
        greenIcon?.isTemplate = false
        redIcon?.isTemplate = false
        yellowIcon?.isTemplate = false

        // Resize icons to fit menu bar (typically 16x16 or 18x18)
        let iconSize = NSSize(width: 18, height: 18)
        grayIcon?.size = iconSize
        greenIcon?.size = iconSize
        redIcon?.size = iconSize
        yellowIcon?.size = iconSize
    }

    /// Tint an image with a specific color
    private func tintImage(_ image: NSImage, with color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()

        // Draw the original image
        image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1.0)

        // Apply color tint with multiply blend mode
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)

        tinted.unlockFocus()
        return tinted
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

        // Failures section (populated dynamically)
        // Tag 102 marks the start of the failures section
        let failuresSectionStart = NSMenuItem.separator()
        failuresSectionStart.tag = 102
        failuresSectionStart.isHidden = true
        menu.addItem(failuresSectionStart)

        // Updating section (populated dynamically) — actively building resources
        // Tag 103 marks the start of the updating section
        let updatingSectionStart = NSMenuItem.separator()
        updatingSectionStart.tag = 103
        updatingSectionStart.isHidden = true
        menu.addItem(updatingSectionStart)

        // Waiting section (populated dynamically) — pending resources not actively building
        // Tag 105 marks the start of the waiting section
        let waitingSectionStart = NSMenuItem.separator()
        waitingSectionStart.tag = 105
        waitingSectionStart.isHidden = true
        menu.addItem(waitingSectionStart)

        menu.addItem(NSMenuItem.separator())

        // Open in Browser
        let openMenuItem = NSMenuItem(
            title: "Open Tilt in Browser",
            action: #selector(openInBrowser),
            keyEquivalent: "o"
        )
        openMenuItem.target = self
        menu.addItem(openMenuItem)

        // View on GitHub with version
        let githubMenuItem = NSMenuItem(
            title: "TiltBar v\(appVersion)",
            action: #selector(openGitHub),
            keyEquivalent: "g"
        )
        githubMenuItem.target = self
        menu.addItem(githubMenuItem)

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

        // Development Mode submenu (hidden by default, shown when Option key is held)
        let devModeMenuItem = NSMenuItem(
            title: "Development Mode",
            action: nil,
            keyEquivalent: ""
        )
        devModeMenuItem.tag = 200 // Tag to find it later for hiding/showing

        let devModeSubmenu = NSMenu()

        // All Success
        let allSuccessItem = NSMenuItem(
            title: "All Success",
            action: #selector(setDevModeAllSuccess),
            keyEquivalent: ""
        )
        allSuccessItem.target = self
        allSuccessItem.tag = 201
        devModeSubmenu.addItem(allSuccessItem)

        // With Warnings
        let withWarningsItem = NSMenuItem(
            title: "With Warnings",
            action: #selector(setDevModeWithWarnings),
            keyEquivalent: ""
        )
        withWarningsItem.target = self
        withWarningsItem.tag = 202
        devModeSubmenu.addItem(withWarningsItem)

        // With Errors
        let withErrorsItem = NSMenuItem(
            title: "With Errors",
            action: #selector(setDevModeWithErrors),
            keyEquivalent: ""
        )
        withErrorsItem.target = self
        withErrorsItem.tag = 203
        devModeSubmenu.addItem(withErrorsItem)

        // In Progress
        let inProgressItem = NSMenuItem(
            title: "In Progress",
            action: #selector(setDevModeInProgress),
            keyEquivalent: ""
        )
        inProgressItem.target = self
        inProgressItem.tag = 204
        devModeSubmenu.addItem(inProgressItem)

        // Disconnected
        let disconnectedItem = NSMenuItem(
            title: "Disconnected",
            action: #selector(setDevModeDisconnected),
            keyEquivalent: ""
        )
        disconnectedItem.target = self
        disconnectedItem.tag = 205
        devModeSubmenu.addItem(disconnectedItem)

        devModeSubmenu.addItem(NSMenuItem.separator())

        // Cycle All States
        let cycleStatesItem = NSMenuItem(
            title: "Cycle All States",
            action: #selector(setDevModeCycleAllStates),
            keyEquivalent: ""
        )
        cycleStatesItem.target = self
        cycleStatesItem.tag = 206
        devModeSubmenu.addItem(cycleStatesItem)

        devModeSubmenu.addItem(NSMenuItem.separator())

        // Return to Live Mode
        let liveItem = NSMenuItem(
            title: "Return to Live Mode",
            action: #selector(setDevModeLive),
            keyEquivalent: ""
        )
        liveItem.target = self
        liveItem.tag = 207
        devModeSubmenu.addItem(liveItem)

        devModeMenuItem.submenu = devModeSubmenu
        devModeMenuItem.isHidden = true // Hidden by default
        menu.addItem(devModeMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitMenuItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        menu.delegate = self
        statusItem?.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Show/hide development mode menu based on Option key
        if let devModeMenuItem = menu.item(withTag: 200) {
            let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
            devModeMenuItem.isHidden = !optionKeyPressed
        }

        // Update checkmarks for development mode items
        updateDevModeCheckmarks(menu)

        // Reset the last displayed countdown to force initial update
        lastDisplayedCountdown = nil

        // Start timer to update retry countdown every second while menu is open
        menuUpdateTimer?.invalidate()
        menuUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateMenuStatus()
        }
        // Update immediately
        updateMenuStatus()
    }

    func menuDidClose(_ menu: NSMenu) {
        // Stop the update timer when menu closes
        menuUpdateTimer?.invalidate()
        menuUpdateTimer = nil
        lastDisplayedCountdown = nil
    }

    private func updateDevModeCheckmarks(_ menu: NSMenu) {
        // Find the development mode submenu
        guard let devModeMenuItem = menu.item(withTag: 200),
              let devModeSubmenu = devModeMenuItem.submenu else {
            return
        }

        // Clear all checkmarks first
        for tag in 201...207 {
            if let item = devModeSubmenu.item(withTag: tag) {
                item.state = .off
            }
        }

        // Set checkmark for current mode
        let currentTag: Int
        switch developmentMode {
        case .live:
            currentTag = 207
        case .allSuccess:
            currentTag = 201
        case .withWarnings:
            currentTag = 202
        case .withErrors:
            currentTag = 203
        case .inProgress:
            currentTag = 204
        case .disconnected:
            currentTag = 205
        case .cycleAllStates:
            currentTag = 206
        }

        if let item = devModeSubmenu.item(withTag: currentTag) {
            item.state = .on
        }
    }

    // MARK: - Status Updates

    private func handleStatusUpdate(_ status: ResourceStatus) {
        // Ignore live updates when in development mode
        if developmentMode == .live {
            currentStatus = status
            updateDisplay()
        }
    }

    private func handleConnectionStateChange(_ state: ConnectionState) {
        // Ignore live updates when in development mode
        if developmentMode == .live {
            currentConnectionState = state
            updateDisplay()
        }
    }

    private func handleFailuresUpdate(_ failures: [FailureInfo]) {
        // Ignore live updates when in development mode
        if developmentMode == .live {
            currentFailures = failures
            updateFailuresInMenu()
        }
    }

    private func handleInProgressUpdate(_ inProgress: [InProgressInfo]) {
        // Ignore live updates when in development mode
        if developmentMode == .live {
            currentInProgress = inProgress
            updateInProgressInMenu()
        }
    }

    private func handlePendingResourcesUpdate(_ pendingResources: [PendingResourceInfo]) {
        // Ignore live updates when in development mode
        if developmentMode == .live {
            currentPendingResources = pendingResources
            updatePendingResourcesInMenu()
        }
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

            // Set the title text with colors
            let attributedText = buildStatusBarAttributedText()
            if attributedText.length > 0 {
                button.attributedTitle = attributedText
            } else {
                button.attributedTitle = NSAttributedString(string: "")
            }
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
    /// Gray logo: if not connected (disconnected, connecting, server down)
    /// Red logo: if errors > 0
    /// Yellow logo: if warnings > 0 but no errors
    /// Green logo: otherwise (all success, when connected)
    private func chooseIcon() -> NSImage? {
        // ALWAYS check connection state first - if not connected, MUST be gray
        if currentConnectionState != .connected {
            return grayIcon
        }

        // Only when connected do we check resource status for colors
        // If there are errors, show red logo
        if currentStatus.error > 0 {
            return redIcon
        }

        // If there are warnings (but no errors), show yellow logo
        if currentStatus.warning > 0 {
            return yellowIcon
        }

        // Everything is green (only when connected and no errors/warnings)
        return greenIcon
    }

    /// Build the attributed text to show in the status bar with colored numbers
    /// Format: red yellow inprogress green (only showing counts > 0)
    /// Only shows numbers, never any text labels
    private func buildStatusBarAttributedText() -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Add leading space for padding
        result.append(NSAttributedString(string: " "))

        switch currentConnectionState {
        case .disconnected, .connecting, .serverDown:
            // All non-connected states: just show gray icon, no text/numbers
            return NSAttributedString(string: "")
        case .connected:
            // If everything is green/successful, show no text (just icon)
            if currentStatus.error == 0 && currentStatus.warning == 0 && currentStatus.inProgress == 0 && currentStatus.success > 0 {
                return NSAttributedString(string: "")
            }

            // If no resources, still just show icon (no text)
            if currentStatus.total == 0 {
                return NSAttributedString(string: "")
            }

            // Build format with colored numbers
            var parts: [NSAttributedString] = []

            // Red count (errors) - only show if > 0
            if currentStatus.error > 0 {
                let errorText = NSAttributedString(
                    string: "\(currentStatus.error)",
                    attributes: [.foregroundColor: NSColor.red]
                )
                parts.append(errorText)
            }

            // Yellow count (warnings) - only show if > 0
            if currentStatus.warning > 0 {
                let warningText = NSAttributedString(
                    string: "\(currentStatus.warning)",
                    attributes: [.foregroundColor: NSColor.yellow]
                )
                parts.append(warningText)
            }

            // Gray count (in progress) - only show if > 0
            if currentStatus.inProgress > 0 {
                let inProgressText = NSAttributedString(
                    string: "\(currentStatus.inProgress)",
                    attributes: [.foregroundColor: NSColor.gray]
                )
                parts.append(inProgressText)
            }

            // Green count (success) - always show when connected with resources
            if currentStatus.success > 0 {
                let successText = NSAttributedString(
                    string: "\(currentStatus.success)",
                    attributes: [.foregroundColor: NSColor.green]
                )
                parts.append(successText)
            }

            // Join parts with spaces
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    result.append(NSAttributedString(string: " "))
                }
                result.append(part)
            }

            return result
        }
    }

    /// Build the text to show in the status menu item
    private func buildStatusText() -> String {
        let connectionText = currentConnectionState.displayText

        if currentConnectionState == .connected {
            return "Status: \(connectionText) - \(currentStatus.summary)"
        } else {
            // Show retry countdown for disconnected states
            let nextRetry = developmentMode == .live ? tiltClient.nextRetryTime : devModeNextRetryTime
            if let nextRetry = nextRetry {
                let secondsUntilRetry = max(0, Int(nextRetry.timeIntervalSinceNow))
                return "Status: \(connectionText) - Retry in \(secondsUntilRetry)s"
            } else {
                return "Status: \(connectionText)"
            }
        }
    }

    /// Update the status menu item (called by timer when menu is open)
    private func updateMenuStatus() {
        // In dev mode disconnected state, simulate retry countdown resetting
        if developmentMode == .disconnected {
            if let nextRetry = devModeNextRetryTime {
                if nextRetry.timeIntervalSinceNow <= 0 {
                    // Reset the countdown to 15 seconds
                    devModeNextRetryTime = Date().addingTimeInterval(15)
                }
            } else {
                // Initialize if somehow nil
                devModeNextRetryTime = Date().addingTimeInterval(15)
            }
        }

        // Get the current countdown value
        let nextRetry = developmentMode == .live ? tiltClient.nextRetryTime : devModeNextRetryTime
        let currentCountdown = nextRetry.map { max(0, Int($0.timeIntervalSinceNow)) }

        // Only update if the countdown value has changed (reduces flickering)
        if currentCountdown != lastDisplayedCountdown {
            lastDisplayedCountdown = currentCountdown
            if let menu = statusItem?.menu,
               let statusMenuItem = menu.item(withTag: 100) {
                statusMenuItem.title = buildStatusText()
            }
        }
    }

    /// Update the In Progress section in the menu
    /// Uses in-place updates to avoid flickering
    private func updateInProgressInMenu() {
        guard let menu = statusItem?.menu else { return }

        // Find the in-progress section separator (tag 103)
        guard let inProgressSectionIndex = menu.items.firstIndex(where: { $0.tag == 103 }) else {
            return
        }

        // Tags for in-progress items: 1030 = header, 1031-1035 = items
        let headerTag = 1030
        let firstItemTag = 1031

        if !currentInProgress.isEmpty {
            // Show the separator
            if let separator = menu.item(withTag: 103) {
                separator.isHidden = false
            }

            // Add or update header with count
            let headerTitle = "Updating: \(currentInProgress.count)"
            if let existingHeader = menu.item(withTag: headerTag) {
                existingHeader.title = headerTitle
            } else {
                let header = NSMenuItem(
                    title: headerTitle,
                    action: nil,
                    keyEquivalent: ""
                )
                header.isEnabled = false
                header.tag = headerTag
                menu.insertItem(header, at: inProgressSectionIndex + 1)
            }

            // Update or add each in-progress resource
            for (index, inProgress) in currentInProgress.enumerated() {
                let itemTag = firstItemTag + index

                // Build title with dependent count if > 0
                var title = "  \(inProgress.resourceName) - \(inProgress.duration)"
                if inProgress.dependentCount > 0 {
                    title += " (\(inProgress.dependentCount) waiting)"
                }

                if let existingItem = menu.item(withTag: itemTag) {
                    // Update existing item in place
                    existingItem.title = title
                    existingItem.representedObject = inProgress
                } else {
                    // Create new item
                    let inProgressItem = NSMenuItem(
                        title: title,
                        action: #selector(openInProgressInBrowser(_:)),
                        keyEquivalent: ""
                    )
                    inProgressItem.target = self
                    inProgressItem.tag = itemTag
                    inProgressItem.representedObject = inProgress
                    menu.insertItem(inProgressItem, at: inProgressSectionIndex + 2 + index)
                }
            }

            // Remove extra items if the list shrank
            for index in min(currentInProgress.count, 5)..<5 {
                let itemTag = firstItemTag + index
                if let item = menu.item(withTag: itemTag) {
                    menu.removeItem(item)
                }
            }
        } else {
            // No in-progress resources, hide the separator and remove all items
            if let separator = menu.item(withTag: 103) {
                separator.isHidden = true
            }
            if let header = menu.item(withTag: headerTag) {
                menu.removeItem(header)
            }
            for index in 0..<5 {
                let itemTag = firstItemTag + index
                if let item = menu.item(withTag: itemTag) {
                    menu.removeItem(item)
                }
            }
        }
    }

    /// Update the Recent Failures section in the menu
    /// Uses in-place updates to avoid flickering
    private func updateFailuresInMenu() {
        guard let menu = statusItem?.menu else { return }

        // Find the failures section separator (tag 102)
        guard let failuresSectionIndex = menu.items.firstIndex(where: { $0.tag == 102 }) else {
            return
        }

        // Tags for failure items: 1020 = header, 1021-1025 = items
        let headerTag = 1020
        let firstItemTag = 1021

        if !currentFailures.isEmpty {
            // Show the separator
            if let separator = menu.item(withTag: 102) {
                separator.isHidden = false
            }

            // Add or update header with count
            let headerTitle = "Failures: \(currentFailures.count)"
            if let existingHeader = menu.item(withTag: headerTag) {
                existingHeader.title = headerTitle
            } else {
                let header = NSMenuItem(
                    title: headerTitle,
                    action: nil,
                    keyEquivalent: ""
                )
                header.isEnabled = false
                header.tag = headerTag
                menu.insertItem(header, at: failuresSectionIndex + 1)
            }

            // Update or add each failure
            for (index, failure) in currentFailures.enumerated() {
                let itemTag = firstItemTag + index
                let title = "  \(failure.resourceName) - \(failure.timeAgo)"

                if let existingItem = menu.item(withTag: itemTag) {
                    // Update existing item in place
                    existingItem.title = title
                    existingItem.representedObject = failure
                    // Update submenu's representedObjects too
                    if let submenu = existingItem.submenu {
                        if let openItem = submenu.items.first {
                            openItem.representedObject = failure
                        }
                        if submenu.items.count > 1 {
                            submenu.items[1].representedObject = failure.resourceName
                        }
                    }
                } else {
                    // Create new item with submenu
                    let failureItem = NSMenuItem(
                        title: title,
                        action: nil,
                        keyEquivalent: ""
                    )
                    failureItem.tag = itemTag
                    failureItem.representedObject = failure

                    // Create submenu for this resource
                    let submenu = NSMenu()

                    let openItem = NSMenuItem(
                        title: "Open in Browser",
                        action: #selector(openFailureInBrowser(_:)),
                        keyEquivalent: ""
                    )
                    openItem.target = self
                    openItem.representedObject = failure
                    submenu.addItem(openItem)

                    let triggerItem = NSMenuItem(
                        title: "Trigger Update",
                        action: #selector(triggerResourceUpdate(_:)),
                        keyEquivalent: ""
                    )
                    triggerItem.target = self
                    triggerItem.representedObject = failure.resourceName
                    submenu.addItem(triggerItem)

                    failureItem.submenu = submenu
                    menu.insertItem(failureItem, at: failuresSectionIndex + 2 + index)
                }
            }

            // Remove extra items if the list shrank
            for index in min(currentFailures.count, 5)..<5 {
                let itemTag = firstItemTag + index
                if let item = menu.item(withTag: itemTag) {
                    menu.removeItem(item)
                }
            }
        } else {
            // No failures, hide the separator and remove all items
            if let separator = menu.item(withTag: 102) {
                separator.isHidden = true
            }
            if let header = menu.item(withTag: headerTag) {
                menu.removeItem(header)
            }
            for index in 0..<5 {
                let itemTag = firstItemTag + index
                if let item = menu.item(withTag: itemTag) {
                    menu.removeItem(item)
                }
            }
        }
    }

    /// Update the Pending Resources section in the menu
    /// Shows all resources that are pending but not actively building
    /// Uses in-place updates to avoid flickering
    private func updatePendingResourcesInMenu() {
        guard let menu = statusItem?.menu else { return }

        // Find the pending section separator (tag 105)
        guard let pendingSectionIndex = menu.items.firstIndex(where: { $0.tag == 105 }) else {
            return
        }

        // Tags for pending items: 1050 = header, 1051-1060 = items
        let headerTag = 1050
        let firstItemTag = 1051
        let maxItems = 10

        if !currentPendingResources.isEmpty {
            // Show the separator
            if let separator = menu.item(withTag: 105) {
                separator.isHidden = false
            }

            // Add or update header with count
            let headerTitle = "Waiting: \(currentPendingResources.count)"
            if let existingHeader = menu.item(withTag: headerTag) {
                existingHeader.title = headerTitle
            } else {
                let header = NSMenuItem(
                    title: headerTitle,
                    action: nil,
                    keyEquivalent: ""
                )
                header.isEnabled = false
                header.tag = headerTag
                menu.insertItem(header, at: pendingSectionIndex + 1)
            }

            // Update or add each pending resource
            for (index, pending) in currentPendingResources.prefix(maxItems).enumerated() {
                let itemTag = firstItemTag + index
                var title = "  \(pending.resourceName)"
                if !pending.waitingOn.isEmpty {
                    title += " → \(pending.detail)"
                }

                if let existingItem = menu.item(withTag: itemTag) {
                    existingItem.title = title
                    existingItem.representedObject = pending
                } else {
                    let pendingItem = NSMenuItem(
                        title: title,
                        action: #selector(openPendingResourceInBrowser(_:)),
                        keyEquivalent: ""
                    )
                    pendingItem.target = self
                    pendingItem.tag = itemTag
                    pendingItem.representedObject = pending
                    menu.insertItem(pendingItem, at: pendingSectionIndex + 2 + index)
                }
            }

            // Remove extra items if the list shrank
            for index in min(currentPendingResources.count, maxItems)..<maxItems {
                let itemTag = firstItemTag + index
                if let item = menu.item(withTag: itemTag) {
                    menu.removeItem(item)
                }
            }
        } else {
            // No pending resources, hide the separator and remove all items
            if let separator = menu.item(withTag: 105) {
                separator.isHidden = true
            }
            if let header = menu.item(withTag: headerTag) {
                menu.removeItem(header)
            }
            for index in 0..<maxItems {
                let itemTag = firstItemTag + index
                if let item = menu.item(withTag: itemTag) {
                    menu.removeItem(item)
                }
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func openInBrowser() {
        // Open the default browser to the Tilt URL
        if let url = URL(string: "http://localhost:10350") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openGitHub() {
        // Open the GitHub release notes page for the current version
        if let url = URL(string: "https://github.com/seriousben/tiltbar/releases/tag/v\(releaseVersion)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func reconnectNow() {
        tiltClient.reconnectNow()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openFailureInBrowser(_ sender: NSMenuItem) {
        // Get the failure info from the menu item
        guard let failure = sender.representedObject as? FailureInfo else {
            return
        }

        // Open the failure's resource URL in the browser
        if let url = URL(string: failure.webURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInProgressInBrowser(_ sender: NSMenuItem) {
        // Get the in-progress info from the menu item
        guard let inProgress = sender.representedObject as? InProgressInfo else {
            return
        }

        // Open the in-progress resource URL in the browser
        if let url = URL(string: inProgress.webURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func triggerResourceUpdate(_ sender: NSMenuItem) {
        // Get the resource name from the menu item
        guard let resourceName = sender.representedObject as? String else {
            return
        }

        // Trigger the update via TiltClient
        tiltClient.triggerUpdate(resourceName: resourceName)
    }

    @objc private func openPendingResourceInBrowser(_ sender: NSMenuItem) {
        guard let pending = sender.representedObject as? PendingResourceInfo else {
            return
        }
        if let url = URL(string: pending.webURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Development Mode Actions

    @objc private func setDevModeAllSuccess() {
        setDevelopmentMode(.allSuccess)
    }

    @objc private func setDevModeWithWarnings() {
        setDevelopmentMode(.withWarnings)
    }

    @objc private func setDevModeWithErrors() {
        setDevelopmentMode(.withErrors)
    }

    @objc private func setDevModeInProgress() {
        setDevelopmentMode(.inProgress)
    }

    @objc private func setDevModeDisconnected() {
        setDevelopmentMode(.disconnected)
    }

    @objc private func setDevModeCycleAllStates() {
        setDevelopmentMode(.cycleAllStates)
    }

    @objc private func setDevModeLive() {
        setDevelopmentMode(.live)
    }

    private func setDevelopmentMode(_ mode: DevelopmentMode) {
        // Stop any existing cycle timer
        cycleTimer?.invalidate()
        cycleTimer = nil
        cycleIndex = 0

        developmentMode = mode

        // Apply the test data immediately
        applyDevelopmentModeData()

        // Start cycle timer if in cycle mode
        if mode == .cycleAllStates {
            startCycleTimer()
        }
    }

    private func applyDevelopmentModeData() {
        switch developmentMode {
        case .live:
            // Return to live mode - clear dev mode state and let TiltClient handle everything
            devModeNextRetryTime = nil  // Clear dev mode retry time
            // Don't manually set currentConnectionState or currentStatus here
            // Let the TiltClient's callbacks handle it via handleStatusUpdate/handleConnectionStateChange
            tiltClient.reconnectNow()
            // The reconnectNow will trigger connection state updates through the normal callbacks
            break

        case .allSuccess:
            devModeNextRetryTime = nil
            currentStatus = ResourceStatus(
                inProgress: 0,
                success: 5,
                warning: 0,
                error: 0
            )
            currentConnectionState = .connected
            updateDisplay()

        case .withWarnings:
            devModeNextRetryTime = nil
            currentStatus = ResourceStatus(
                inProgress: 0,
                success: 3,
                warning: 2,
                error: 0
            )
            currentConnectionState = .connected
            updateDisplay()

        case .withErrors:
            devModeNextRetryTime = nil
            currentStatus = ResourceStatus(
                inProgress: 0,
                success: 3,
                warning: 1,
                error: 1
            )
            currentConnectionState = .connected
            updateDisplay()

        case .inProgress:
            devModeNextRetryTime = nil
            currentStatus = ResourceStatus(
                inProgress: 2,
                success: 3,
                warning: 0,
                error: 0
            )
            currentConnectionState = .connected
            updateDisplay()

        case .disconnected:
            currentStatus = ResourceStatus(
                inProgress: 0,
                success: 0,
                warning: 0,
                error: 0
            )
            currentConnectionState = .disconnected
            // Simulate a retry countdown (15 seconds)
            devModeNextRetryTime = Date().addingTimeInterval(15)
            updateDisplay()

        case .cycleAllStates:
            devModeNextRetryTime = nil
            // Initial state will be set by the timer
            cycleThroughStates()
        }
    }

    private func startCycleTimer() {
        // Cycle through states every 2.5 seconds
        cycleTimer = Timer.scheduledTimer(
            withTimeInterval: 2.5,
            repeats: true
        ) { [weak self] _ in
            self?.cycleThroughStates()
        }
    }

    private func cycleThroughStates() {
        // Define the sequence of states to cycle through
        let states: [(ResourceStatus, ConnectionState)] = [
            // All Success
            (ResourceStatus(inProgress: 0, success: 5, warning: 0, error: 0), .connected),
            // In Progress
            (ResourceStatus(inProgress: 2, success: 3, warning: 0, error: 0), .connected),
            // With Warnings
            (ResourceStatus(inProgress: 0, success: 3, warning: 2, error: 0), .connected),
            // With Errors
            (ResourceStatus(inProgress: 0, success: 3, warning: 1, error: 1), .connected),
            // Disconnected
            (ResourceStatus(inProgress: 0, success: 0, warning: 0, error: 0), .disconnected)
        ]

        // Get the current state
        let (status, connectionState) = states[cycleIndex]
        currentStatus = status
        currentConnectionState = connectionState
        updateDisplay()

        // Move to next state
        cycleIndex = (cycleIndex + 1) % states.count
    }
}

