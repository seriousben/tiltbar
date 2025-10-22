import Cocoa

// This is the entry point for our macOS status bar app
// In Swift, the main.swift file is special - it gets executed directly

// Create the shared NSApplication instance
// This is the main object that manages the app lifecycle
let app = NSApplication.shared

// Create our app delegate
// The delegate receives callbacks about app lifecycle events
let delegate = AppDelegate()
app.delegate = delegate

// Set the activation policy to accessory
// This means:
// - The app won't appear in the Dock
// - The app won't appear in Cmd+Tab
// - The app will only show in the menu bar
// This is what makes it a "menu bar only" app
app.setActivationPolicy(.accessory)

// Start the app's main event loop
// This function never returns - it keeps the app running
// and processing events (clicks, keyboard input, etc.)
app.run()
