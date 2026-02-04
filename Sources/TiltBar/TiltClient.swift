import Foundation

/// TiltClient manages the connection to Tilt by using the `tilt` CLI
///
/// ## How it works:
/// 1. Spawns `tilt get uiresource -w -o json` as a subprocess
/// 2. Reads JSON output line-by-line (pretty-printed, multi-line JSON)
/// 3. Buffers lines and tracks brace depth to detect complete JSON objects
/// 4. Parses UIResource objects and aggregates their status
/// 5. Auto-reconnects with exponential backoff if the process exits
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

    /// The running tilt process
    private var process: Process?

    /// Dictionary of all known resources by name
    private var resources: [String: UIResource] = [:]

    /// List of recent failures (most recent first, max 5)
    private var recentFailures: [FailureInfo] = []

    /// List of resources currently in progress (sorted by dependent count, max 5)
    private var inProgressResources: [InProgressInfo] = []

    /// List of pending resources that are blocking others (sorted by dependent count, max 5)
    private var pendingBlockers: [PendingBlockerInfo] = []

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

    /// Called when the list of pending blockers changes
    var onPendingBlockersUpdate: (([PendingBlockerInfo]) -> Void)?

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

        // Start a new watch task
        watchTask = Task {
            await runWatchLoop()
        }
    }

    /// Stop watching and disconnect
    func stop() {
        watchTask?.cancel()
        watchTask = nil

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

    /// Trigger an update/rebuild for a specific resource
    func triggerUpdate(resourceName: String) {
        Task {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tiltPath)
                process.arguments = ["trigger", resourceName]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    print("Failed to trigger \(resourceName): \(output)")
                } else {
                    print("Triggered update for \(resourceName)")
                }
            } catch {
                print("Error triggering update for \(resourceName): \(error)")
            }
        }
    }

    /// Refresh the dependency graph from Tilt's engine state
    func refreshDependencyGraph() {
        Task {
            await fetchDependencyGraph()
        }
    }

    /// Fetch and build the dependency graph (reverse mapping)
    private func fetchDependencyGraph() async {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tiltPath)
            process.arguments = ["dump", "engine"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

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
            print("Error fetching dependency graph: \(error)")
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

        // Update dependent counts for pending blockers
        for i in 0..<pendingBlockers.count {
            let resourceName = pendingBlockers[i].resourceName
            pendingBlockers[i].dependentCount = dependentsMap[resourceName]?.count ?? 0
        }

        // Remove any that no longer have dependents
        pendingBlockers.removeAll { $0.dependentCount == 0 }

        // Sort by dependent count (descending)
        pendingBlockers.sort { $0.dependentCount > $1.dependentCount }

        // Emit update
        emitPendingBlockers()
    }

    // MARK: - Watch Loop

    /// Main loop that maintains the connection and handles retries
    private func runWatchLoop() async {
        print("TiltClient: Starting watch loop")
        // Keep trying to connect until the task is cancelled
        while !Task.isCancelled {
            do {
                print("TiltClient: Connecting...")
                updateConnectionState(.connecting)
                try await watchResources()
                print("TiltClient: watchResources returned normally")
            } catch is CancellationError {
                // Task was cancelled, exit cleanly
                print("TiltClient: Cancelled")
                break
            } catch let error as NSError {
                // Handle errors
                if error.domain == NSCocoaErrorDomain && error.code == 4 {
                    // Executable not found - tilt not installed or wrong path
                    print("TiltClient: tilt CLI not found at \(tiltPath)")
                    updateConnectionState(.serverDown)
                } else {
                    print("TiltClient: Watch error: \(error)")
                    updateConnectionState(.disconnected)
                }
            } catch {
                // Other errors
                updateConnectionState(.disconnected)
                print("TiltClient: Watch error (other): \(error)")
            }

            // Wait before retrying (unless cancelled)
            if !Task.isCancelled {
                print("TiltClient: Retrying in \(currentRetryDelay) seconds...")
                nextRetryTime = Date().addingTimeInterval(currentRetryDelay)
                try? await Task.sleep(for: .seconds(currentRetryDelay))

                // Exponential backoff up to maxRetryDelay
                currentRetryDelay = min(currentRetryDelay * 2, maxRetryDelay)
            }
        }
        print("TiltClient: Watch loop ended")
    }

    /// Watch Tilt resources by spawning the tilt CLI
    /// This runs `tilt get uiresource -w -o json` and processes its output
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

        // Use continuation to bridge callback-based API to async/await
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var jsonBuffer: [String] = []
            var braceDepth = 0
            var lineBuffer = ""
            var continuationResumed = false

            // Handle stdout data
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData

                if data.isEmpty {
                    // EOF - pipe closed
                    return
                }

                guard let text = String(data: data, encoding: .utf8) else { return }

                // Process character by character to handle lines
                for char in text {
                    if char == "\n" {
                        let line = lineBuffer
                        lineBuffer = ""

                        // Skip empty lines when not inside an object
                        if line.isEmpty && braceDepth == 0 {
                            continue
                        }

                        jsonBuffer.append(line)

                        // Count braces
                        for c in line {
                            if c == "{" { braceDepth += 1 }
                            else if c == "}" { braceDepth -= 1 }
                        }

                        // Complete JSON object
                        if braceDepth == 0 && !jsonBuffer.isEmpty {
                            let jsonString = jsonBuffer.joined(separator: "\n")
                            jsonBuffer.removeAll()

                            do {
                                let jsonData = Data(jsonString.utf8)
                                let resource = try JSONDecoder().decode(UIResource.self, from: jsonData)

                                // Successfully connected
                                if self?.connectionState != .connected {
                                    self?.currentRetryDelay = self?.initialRetryDelay ?? 1.0
                                    self?.updateConnectionState(.connected)
                                }

                                self?.handleResourceUpdate(resource)
                            } catch {
                                print("TiltClient: Failed to parse: \(error)")
                            }
                        }
                    } else if char != "\r" {
                        lineBuffer.append(char)
                    }
                }
            }

            // Handle process termination
            newProcess.terminationHandler = { process in
                // Clean up handlers
                stdoutPipe.fileHandleForReading.readabilityHandler = nil

                guard !continuationResumed else { return }
                continuationResumed = true

                if process.terminationStatus != 0 {
                    let stderrData = stderrPipe.fileHandleForReading.availableData
                    let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let msg = stderrText.isEmpty ? "exit code \(process.terminationStatus)" : stderrText
                    print("TiltClient: tilt exited: \(msg)")
                    continuation.resume(throwing: NSError(domain: "TiltClient", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg]))
                } else {
                    print("TiltClient: tilt exited normally")
                    continuation.resume(throwing: NSError(domain: "TiltClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "tilt process exited"]))
                }
            }

            // Start the process
            do {
                try newProcess.run()
                nextRetryTime = nil
            } catch {
                continuationResumed = true
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Event Handling

    /// Process a UIResource update
    private func handleResourceUpdate(_ resource: UIResource) {
        let resourceName = resource.metadata.name

        // Update our local cache
        resources[resourceName] = resource

        // Track failures and in-progress resources
        trackResourceStatus(resource)

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

            // Remove from pending blockers if it was there (now actively updating)
            if let index = pendingBlockers.firstIndex(where: { $0.resourceName == resourceName }) {
                pendingBlockers.remove(at: index)
                emitPendingBlockers()
            }
        } else {
            // Resource is not actively updating - remove from in-progress list if present
            if let index = inProgressResources.firstIndex(where: { $0.resourceName == resourceName }) {
                inProgressResources.remove(at: index)
                emitInProgress()
            }

            // Check if this is a pending blocker (not ok/ready and has dependents)
            let dependentCount = dependentsMap[resourceName]?.count ?? 0
            let isPending = status == .inProgress  // Pending status (not actively building)
            let isBlockingOthers = dependentCount > 0

            if isPending && isBlockingOthers {
                // Add or update in pending blockers
                if let existingIndex = pendingBlockers.firstIndex(where: { $0.resourceName == resourceName }) {
                    pendingBlockers[existingIndex] = PendingBlockerInfo(
                        resourceName: resourceName,
                        dependentCount: dependentCount
                    )
                } else {
                    pendingBlockers.append(
                        PendingBlockerInfo(
                            resourceName: resourceName,
                            dependentCount: dependentCount
                        )
                    )
                }

                // Sort by dependent count (descending)
                pendingBlockers.sort { $0.dependentCount > $1.dependentCount }

                // Keep only the top 5
                if pendingBlockers.count > 5 {
                    pendingBlockers = Array(pendingBlockers.prefix(5))
                }

                emitPendingBlockers()
            } else {
                // Not a pending blocker - remove if present
                if let index = pendingBlockers.firstIndex(where: { $0.resourceName == resourceName }) {
                    pendingBlockers.remove(at: index)
                    emitPendingBlockers()
                }
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

    /// Notify the callback with the current list of pending blockers
    private func emitPendingBlockers() {
        // Notify on the main thread (since this will update UI)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onPendingBlockersUpdate?(self.pendingBlockers)
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


