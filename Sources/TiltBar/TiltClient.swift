import Foundation

/// Timestamp-prefixed log for TiltClient diagnostics.
private func tiltLog(_ message: String) {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    print("\(formatter.string(from: now)) TiltClient: \(message)")
}

/// TiltClient manages the connection to Tilt by using the `tilt` CLI
///
/// ## How it works:
/// 1. Spawns `tilt get uiresource -w -o json` as a subprocess
/// 2. Reads JSON output using `FileHandle.bytes.lines` (native Swift async I/O)
/// 3. Buffers lines and tracks brace depth to detect complete JSON objects
/// 4. Parses UIResource objects and aggregates their status
/// 5. Auto-reconnects with exponential backoff if the process exits
///
/// A terminationHandler safety net force-closes the pipe if the process exits
/// without delivering EOF, guaranteeing the read loop always terminates.
///
/// This approach is simpler than implementing Tilt's Protobuf+WebSocket protocol
/// and leverages the official Tilt CLI for maximum compatibility.
class TiltClient {
    // MARK: - Configuration

    /// Path to the tilt binary
    private let tiltPath: String

    /// Maximum retry delay (30 seconds)
    private let maxRetryDelay: TimeInterval = 30.0

    /// Initial retry delay (1 second)
    private let initialRetryDelay: TimeInterval = 1.0

    // MARK: - State

    /// Current connection state
    private(set) var connectionState: ConnectionState = .disconnected

    /// Current retry delay (increases exponentially up to maxRetryDelay)
    private var currentRetryDelay: TimeInterval

    /// The time when the next retry will happen (nil if connected)
    private(set) var nextRetryTime: Date?

    /// Task that's currently running the watch connection
    private var watchTask: Task<Void, Never>?

    /// Task that clears stale state after a grace period on disconnect.
    /// Cancelled if we reconnect before it fires.
    private var staleClearTask: Task<Void, Never>?

    /// How long to wait after disconnect before clearing stale resource data
    private let staleClearDelay: TimeInterval = 5.0

    /// The running tilt process
    private var process: Process?

    /// Dictionary of all known resources by name
    private var resources: [String: UIResource] = [:]

    /// List of recent failures (most recent first, max 5)
    private var recentFailures: [FailureInfo] = []

    /// List of resources currently in progress (sorted by dependent count, max 5)
    private var inProgressResources: [InProgressInfo] = []

    /// List of resources that are pending but not actively building
    private var pendingResources: [PendingResourceInfo] = []

    /// Dependency graph: maps resource name to list of resources that depend on it
    /// (reverse dependency map - used to count how many resources are waiting)
    private var dependentsMap: [String: [String]] = [:]

    /// Timer to periodically refresh the dependency graph
    private var dependencyRefreshTimer: Timer?

    // MARK: - Callbacks

    /// Called when the aggregated resource status changes
    var onStatusUpdate: ((ResourceStatus) -> Void)?

    /// Called when the connection state changes
    var onConnectionStateChange: ((ConnectionState) -> Void)?

    /// Called when the list of recent failures changes
    var onFailuresUpdate: (([FailureInfo]) -> Void)?

    /// Called when the list of in-progress resources changes
    var onInProgressUpdate: (([InProgressInfo]) -> Void)?

    /// Called when the list of pending resources changes
    var onPendingResourcesUpdate: (([PendingResourceInfo]) -> Void)?

    // MARK: - Initialization

    init(tiltPath: String = "/opt/homebrew/bin/tilt") {
        self.tiltPath = tiltPath
        self.currentRetryDelay = initialRetryDelay
    }

    // MARK: - Public API

    /// Start watching Tilt resources
    func start() {
        // Cancel any existing watch
        stop()

        // Start a new watch task.
        // Use Task.detached so the watch loop does NOT inherit the main actor.
        // If it inherited the main actor, any blocking call elsewhere on the
        // main actor (e.g. waitUntilExit) would freeze the for-await loop.
        watchTask = Task.detached { [weak self] in
            await self?.runWatchLoop()
        }
    }

    /// Stop watching and disconnect
    func stop() {
        watchTask?.cancel()
        watchTask = nil
        cancelStaleClear()

        // Stop the dependency refresh timer
        DispatchQueue.main.async { [weak self] in
            self?.dependencyRefreshTimer?.invalidate()
            self?.dependencyRefreshTimer = nil
        }

        // Terminate the process if running
        if let process = process, process.isRunning {
            process.terminate()
        }
        process = nil

        updateConnectionState(.disconnected)
    }

    /// Manually trigger a reconnection (resets retry delay)
    func reconnectNow() {
        currentRetryDelay = initialRetryDelay
        start()
    }

    /// Trigger an update/rebuild for a specific resource.
    /// Runs on a GCD queue to avoid blocking the Swift cooperative thread pool.
    func triggerUpdate(resourceName: String) {
        DispatchQueue.global().async { [tiltPath] in
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tiltPath)
                process.arguments = ["trigger", resourceName]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                try process.run()

                // Read pipe data before waitUntilExit to prevent pipe buffer deadlock
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let output = String(data: data, encoding: .utf8) ?? ""
                    tiltLog("Failed to trigger \(resourceName): \(output)")
                } else {
                    tiltLog("Triggered update for \(resourceName)")
                }
            } catch {
                tiltLog("Error triggering update for \(resourceName): \(error)")
            }
        }
    }

    /// Refresh the dependency graph from Tilt's engine state.
    /// Runs on a GCD queue to avoid blocking the Swift cooperative thread pool.
    func refreshDependencyGraph() {
        DispatchQueue.global().async { [weak self] in
            self?.fetchDependencyGraph()
        }
    }

    /// Fetch and build the dependency graph (reverse mapping).
    /// Called on a GCD queue — all calls here are synchronous/blocking, which is
    /// safe on GCD but would starve the Swift cooperative thread pool.
    private func fetchDependencyGraph() {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tiltPath)
            process.arguments = ["dump", "engine"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            try process.run()

            // Read pipe data BEFORE waitUntilExit to prevent pipe buffer deadlock:
            // if the process outputs >64KB, the pipe buffer fills, the process blocks
            // on write, and waitUntilExit would wait forever.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                tiltLog("dependency graph fetch failed (exit \(process.terminationStatus))")
                return
            }

            // Parse the JSON to extract dependencies
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let manifestTargets = json["ManifestTargets"] as? [String: Any] else {
                return
            }

            // Build the reverse dependency map
            var newDependentsMap: [String: [String]] = [:]

            for (_, targetValue) in manifestTargets {
                guard let target = targetValue as? [String: Any],
                      let manifest = target["Manifest"] as? [String: Any],
                      let name = manifest["Name"] as? String else {
                    continue
                }

                // Get this resource's dependencies
                if let deps = manifest["ResourceDependencies"] as? [String] {
                    for dep in deps {
                        // Add this resource as a dependent of 'dep'
                        if newDependentsMap[dep] == nil {
                            newDependentsMap[dep] = []
                        }
                        newDependentsMap[dep]?.append(name)
                    }
                }
            }

            // Update on main thread
            DispatchQueue.main.async { [weak self] in
                self?.dependentsMap = newDependentsMap
                // Re-sort in-progress resources with new dependency info
                self?.updateInProgressSorting()
            }
        } catch {
            tiltLog("Error fetching dependency graph: \(error)")
        }
    }

    /// Update the sorting of in-progress resources and pending blockers based on dependency count
    private func updateInProgressSorting() {
        // Update dependent counts for in-progress resources
        for i in 0..<inProgressResources.count {
            let resourceName = inProgressResources[i].resourceName
            inProgressResources[i].dependentCount = dependentsMap[resourceName]?.count ?? 0
        }

        // Sort by dependent count (descending), then by start time (oldest first for resources with same deps)
        inProgressResources.sort { a, b in
            if a.dependentCount != b.dependentCount {
                return a.dependentCount > b.dependentCount
            }
            return a.startTime < b.startTime
        }

        // Emit update
        emitInProgress()
    }

    /// Schedule clearing stale data after a grace period.
    /// Resets any previously scheduled clear.
    private func scheduleStaleClear() {
        staleClearTask?.cancel()
        staleClearTask = Task {
            try? await Task.sleep(for: .seconds(staleClearDelay))
            guard !Task.isCancelled else { return }
            clearResourceState()
        }
    }

    /// Cancel any pending stale-data clear (called on successful reconnect)
    private func cancelStaleClear() {
        staleClearTask?.cancel()
        staleClearTask = nil
    }

    /// Clear all tracked resource state to prevent showing stale data after disconnect
    private func clearResourceState() {
        resources.removeAll()
        recentFailures.removeAll()
        inProgressResources.removeAll()
        pendingResources.removeAll()
        dependentsMap.removeAll()

        // Notify UI with empty state
        emitStatus()
        emitFailures()
        emitInProgress()
        emitPendingResources()
    }

    // MARK: - Watch Loop

    /// Main loop that maintains the connection and handles retries
    private func runWatchLoop() async {
        tiltLog("Starting watch loop")
        defer { tiltLog("Watch loop ended (isCancelled: \(Task.isCancelled))") }

        // Keep trying to connect until the task is cancelled
        while !Task.isCancelled {
            do {
                tiltLog("Connecting...")
                updateConnectionState(.connecting)
                try await watchResources()
                tiltLog("watchResources returned normally")
            } catch is CancellationError {
                // Task was cancelled, exit cleanly
                tiltLog("Cancelled")
                break
            } catch let error as NSError {
                // Schedule clearing stale data after a grace period.
                // If we reconnect quickly the clear is cancelled,
                // avoiding a flash of empty state.
                scheduleStaleClear()

                // Handle errors
                if error.domain == NSCocoaErrorDomain && error.code == 4 {
                    // Executable not found - tilt not installed or wrong path
                    tiltLog("tilt CLI not found at \(tiltPath)")
                    updateConnectionState(.serverDown)
                } else {
                    tiltLog("Watch error: \(error)")
                    updateConnectionState(.disconnected)
                }
            } catch {
                // Schedule clearing stale data after a grace period
                scheduleStaleClear()

                // Other errors
                updateConnectionState(.disconnected)
                tiltLog("Watch error (other): \(error)")
            }

            // Wait before retrying (unless cancelled)
            guard !Task.isCancelled else {
                tiltLog("Task cancelled, skipping retry")
                break
            }

            tiltLog("Retrying in \(currentRetryDelay) seconds...")
            nextRetryTime = Date().addingTimeInterval(currentRetryDelay)

            do {
                // Use nanoseconds API for reliability across all macOS 13.x versions
                // (Duration-based Task.sleep had issues on early macOS 13 releases)
                try await Task.sleep(nanoseconds: UInt64(currentRetryDelay * 1_000_000_000))
            } catch {
                tiltLog("Sleep interrupted (isCancelled: \(Task.isCancelled)): \(error)")
                // If cancelled, the while loop condition will handle exiting
                if Task.isCancelled {
                    break
                }
                // For any other unexpected error, continue with retry immediately
            }

            // Exponential backoff up to maxRetryDelay
            currentRetryDelay = min(currentRetryDelay * 2, maxRetryDelay)
        }
    }

    /// Watch Tilt resources by spawning the tilt CLI.
    /// This runs `tilt get uiresource -w -o json` and processes its output.
    ///
    /// Uses FileHandle.bytes.lines (native Swift async I/O) to read process
    /// output. A terminationHandler acts as a safety net: if the pipe doesn't
    /// close promptly after the process exits, it force-closes the read end
    /// to guarantee the read loop terminates and reconnection can proceed.
    private func watchResources() async throws {
        // Create a new process
        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: tiltPath)
        newProcess.arguments = ["get", "uiresource", "-w", "-o", "json"]

        // Create pipes
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        newProcess.standardOutput = stdoutPipe
        newProcess.standardError = stderrPipe

        // Store the process
        process = newProcess

        // Safety net: when the process exits, force-close the pipe's read end
        // after a short delay. Normally EOF arrives immediately when the process
        // exits, but this guard prevents the read loop from hanging indefinitely
        // if the pipe doesn't close for any reason (e.g., the process exits
        // before the for-await loop begins iterating).
        newProcess.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let msg = stderrText.isEmpty ? "exit code \(proc.terminationStatus)" : stderrText
                tiltLog("tilt exited: \(msg)")
            } else {
                tiltLog("tilt exited normally")
            }

            // Force-close the read end after a delay to unblock the read loop.
            // If EOF already arrived, the close is harmless (throws, caught by try?).
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                try? stdoutPipe.fileHandleForReading.close()
            }
        }

        // Start the process
        try newProcess.run()

        // Process started successfully
        nextRetryTime = nil

        // Read lines using Swift's native async byte sequence.
        // This replaces the previous readabilityHandler + AsyncStream bridge,
        // which had a race condition: if the process exited before the for-await
        // loop began iterating, the stream's finish() signal could be lost,
        // causing the read loop to hang forever and preventing reconnection.
        var jsonBuffer: [String] = []
        var braceDepth = 0

        do {
            for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                // Skip empty lines outside JSON objects
                if line.isEmpty && braceDepth == 0 {
                    continue
                }

                jsonBuffer.append(String(line))

                // Track brace depth to detect complete JSON objects
                for c in line {
                    if c == "{" { braceDepth += 1 }
                    else if c == "}" { braceDepth -= 1 }
                }

                // Complete JSON object detected
                if braceDepth == 0 && !jsonBuffer.isEmpty {
                    let jsonString = jsonBuffer.joined(separator: "\n")
                    jsonBuffer.removeAll()

                    do {
                        let jsonData = Data(jsonString.utf8)
                        let resource = try JSONDecoder().decode(UIResource.self, from: jsonData)

                        // First successful parse means we're truly connected
                        if connectionState != .connected {
                            tiltLog("Connected")
                            currentRetryDelay = initialRetryDelay
                            updateConnectionState(.connected)
                        }

                        handleResourceUpdate(resource)
                    } catch {
                        tiltLog("Failed to parse: \(error)")
                    }
                }
            }
            tiltLog("stdout reached EOF")
        } catch is CancellationError {
            tiltLog("watch cancelled")
            throw CancellationError()
        } catch {
            // bytes.lines throws when the file handle is closed (our safety net)
            // or on other I/O errors — this is expected when the process exits
            tiltLog("pipe read ended: \(error)")
        }

        // Ensure the process is stopped
        if newProcess.isRunning {
            newProcess.terminate()
        }

        // Trigger reconnection
        tiltLog("watch ended, will reconnect")
        throw NSError(
            domain: "TiltClient",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "tilt watch ended"]
        )
    }

    // MARK: - Event Handling

    /// Process a UIResource update
    private func handleResourceUpdate(_ resource: UIResource) {
        let resourceName = resource.metadata.name

        // Update our local cache
        resources[resourceName] = resource

        // Track failures, in-progress, and pending resources
        trackResourceStatus(resource)
        trackPendingStatus(resource)

        // Recalculate and emit the aggregated status
        emitStatus()
    }

    /// Track resource status (failures and in-progress) and update the lists
    private func trackResourceStatus(_ resource: UIResource) {
        let resourceName = resource.metadata.name
        let status = resource.determineStatus()

        // Track failures
        if status == .error {
            // Extract error message from build history
            let errorMessage = resource.status?.buildHistory?.first?.error ?? "Unknown error"

            // Parse timestamp from build history or use current time
            let timestamp: Date
            if let finishTimeStr = resource.status?.buildHistory?.first?.finishTime {
                // Parse ISO8601 timestamp
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                timestamp = formatter.date(from: finishTimeStr) ?? Date()
            } else {
                timestamp = Date()
            }

            // Check if this resource is already in the failures list
            if let existingIndex = recentFailures.firstIndex(where: { $0.resourceName == resourceName }) {
                // Update the existing failure with new timestamp/error
                recentFailures[existingIndex] = FailureInfo(
                    resourceName: resourceName,
                    errorMessage: errorMessage,
                    timestamp: timestamp
                )
            } else {
                // Add new failure
                recentFailures.insert(
                    FailureInfo(
                        resourceName: resourceName,
                        errorMessage: errorMessage,
                        timestamp: timestamp
                    ),
                    at: 0
                )
            }

            // Keep only the 5 most recent failures, sorted by timestamp (most recent first)
            recentFailures.sort { $0.timestamp > $1.timestamp }
            if recentFailures.count > 5 {
                recentFailures = Array(recentFailures.prefix(5))
            }

            // Emit failures update
            emitFailures()
        } else {
            // Resource is no longer in error state - remove from failures list
            if let index = recentFailures.firstIndex(where: { $0.resourceName == resourceName }) {
                recentFailures.remove(at: index)
                emitFailures()
            }
        }

        // Track actively updating resources (only those with currentBuild, not pending ones)
        // We check for currentBuild directly rather than using status == .inProgress
        // because pending resources are waiting on dependencies, not actually updating
        let isActivelyUpdating = resource.status?.currentBuild != nil

        if isActivelyUpdating {
            // Get start time from currentBuild
            let startTime: Date
            if let startTimeStr = resource.status?.currentBuild?.startTime {
                // Parse ISO8601 timestamp
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                startTime = formatter.date(from: startTimeStr) ?? Date()
            } else {
                startTime = Date()
            }

            // Get the dependent count from the dependency map
            let dependentCount = dependentsMap[resourceName]?.count ?? 0

            // Check if this resource is already in the in-progress list
            if let existingIndex = inProgressResources.firstIndex(where: { $0.resourceName == resourceName }) {
                // Update the existing in-progress info
                inProgressResources[existingIndex] = InProgressInfo(
                    resourceName: resourceName,
                    startTime: startTime,
                    dependentCount: dependentCount
                )
            } else {
                // Add new in-progress resource
                inProgressResources.append(
                    InProgressInfo(
                        resourceName: resourceName,
                        startTime: startTime,
                        dependentCount: dependentCount
                    )
                )
            }

            // Sort by dependent count (descending), then by start time (oldest first for resources with same deps)
            inProgressResources.sort { a, b in
                if a.dependentCount != b.dependentCount {
                    return a.dependentCount > b.dependentCount
                }
                return a.startTime < b.startTime  // Oldest first within same priority
            }

            // Keep only the top 5 in-progress resources
            if inProgressResources.count > 5 {
                inProgressResources = Array(inProgressResources.prefix(5))
            }

            // Emit in-progress update
            emitInProgress()
        } else {
            // Resource is not actively updating - remove from in-progress list if present
            if let index = inProgressResources.firstIndex(where: { $0.resourceName == resourceName }) {
                inProgressResources.remove(at: index)
                emitInProgress()
            }
        }
    }

    /// Track pending resources: those with inProgress status but not actively building.
    /// This catches all pending resources regardless of whether they have waiting.on info.
    private func trackPendingStatus(_ resource: UIResource) {
        let resourceName = resource.metadata.name
        let status = resource.determineStatus()
        let isActivelyBuilding = resource.status?.currentBuild != nil

        // Pending = shows as inProgress but not actively building
        if status == .inProgress && !isActivelyBuilding {
            let waiting = resource.status?.waiting
            let waitingOnNames = waiting?.on?.compactMap { $0.name } ?? []
            let info = PendingResourceInfo(
                resourceName: resourceName,
                waitingOn: waitingOnNames,
                reason: waiting?.reason
            )

            if let existingIndex = pendingResources.firstIndex(where: { $0.resourceName == resourceName }) {
                pendingResources[existingIndex] = info
            } else {
                pendingResources.append(info)
            }

            // Sort alphabetically
            pendingResources.sort { $0.resourceName < $1.resourceName }

            emitPendingResources()
        } else {
            // No longer pending — remove if present
            if let index = pendingResources.firstIndex(where: { $0.resourceName == resourceName }) {
                pendingResources.remove(at: index)
                emitPendingResources()
            }
        }
    }

    /// Notify the callback with the current list of failures
    private func emitFailures() {
        // Notify on the main thread (since this will update UI)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onFailuresUpdate?(self.recentFailures)
        }
    }

    /// Notify the callback with the current list of in-progress resources
    private func emitInProgress() {
        // Notify on the main thread (since this will update UI)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onInProgressUpdate?(self.inProgressResources)
        }
    }

    /// Notify the callback with the current list of pending resources
    private func emitPendingResources() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onPendingResourcesUpdate?(self.pendingResources)
        }
    }

    /// Calculate the current aggregated status and notify the callback
    private func emitStatus() {
        var status = ResourceStatus()

        // Count resources by status
        for resource in resources.values {
            switch resource.determineStatus() {
            case .inProgress:
                status.inProgress += 1
            case .success:
                status.success += 1
            case .warning:
                status.warning += 1
            case .error:
                status.error += 1
            case .unknown:
                // Treat unknown as success for now
                status.success += 1
            }
        }

        // Notify on the main thread (since this will update UI)
        DispatchQueue.main.async { [weak self] in
            self?.onStatusUpdate?(status)
        }
    }

    /// Update the connection state and notify the callback
    private func updateConnectionState(_ newState: ConnectionState) {
        connectionState = newState

        // Start/stop dependency refresh timer based on connection state
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if newState == .connected {
                // Reconnected in time - cancel any pending stale-data clear
                self.cancelStaleClear()

                // Fetch dependency graph immediately on connect
                self.refreshDependencyGraph()

                // Start periodic refresh (every 30 seconds)
                self.dependencyRefreshTimer?.invalidate()
                self.dependencyRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
                    self?.refreshDependencyGraph()
                }
            } else {
                // Stop the timer when not connected
                self.dependencyRefreshTimer?.invalidate()
                self.dependencyRefreshTimer = nil
            }
        }

        // Notify on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionStateChange?(newState)
        }
    }
}


