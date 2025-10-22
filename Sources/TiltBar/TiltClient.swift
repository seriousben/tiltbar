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

    /// Task that's currently running the watch connection
    private var watchTask: Task<Void, Never>?

    /// The running tilt process
    private var process: Process?

    /// Dictionary of all known resources by name
    private var resources: [String: UIResource] = [:]

    // MARK: - Callbacks

    /// Called when the aggregated resource status changes
    var onStatusUpdate: ((ResourceStatus) -> Void)?

    /// Called when the connection state changes
    var onConnectionStateChange: ((ConnectionState) -> Void)?

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

    // MARK: - Watch Loop

    /// Main loop that maintains the connection and handles retries
    private func runWatchLoop() async {
        // Keep trying to connect until the task is cancelled
        while !Task.isCancelled {
            do {
                updateConnectionState(.connecting)
                try await watchResources()
            } catch is CancellationError {
                // Task was cancelled, exit cleanly
                break
            } catch let error as NSError {
                // Handle errors
                if error.domain == NSCocoaErrorDomain && error.code == 4 {
                    // Executable not found - tilt not installed or wrong path
                    print("Error: tilt CLI not found at \(tiltPath)")
                    updateConnectionState(.serverDown)
                } else {
                    print("Watch error: \(error)")
                    updateConnectionState(.disconnected)
                }
            } catch {
                // Other errors
                updateConnectionState(.disconnected)
                print("Watch error: \(error)")
            }

            // Wait before retrying (unless cancelled)
            if !Task.isCancelled {
                print("Retrying in \(currentRetryDelay) seconds...")
                try? await Task.sleep(for: .seconds(currentRetryDelay))

                // Exponential backoff up to maxRetryDelay
                currentRetryDelay = min(currentRetryDelay * 2, maxRetryDelay)
            }
        }
    }

    /// Watch Tilt resources by spawning the tilt CLI
    /// This runs `tilt get uiresource -w -o json` and processes its output line by line
    private func watchResources() async throws {
        // Create a new process
        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: tiltPath)
        newProcess.arguments = ["get", "uiresource", "-w", "-o", "json"]

        // Create a pipe to read the process output
        let pipe = Pipe()
        newProcess.standardOutput = pipe
        newProcess.standardError = pipe

        // Store the process
        process = newProcess

        // Start the process
        try newProcess.run()

        // Successfully started! Reset retry delay
        currentRetryDelay = initialRetryDelay
        updateConnectionState(.connected)

        // Read output line by line
        // We use FileHandle's async bytes sequence to read data as it arrives
        let handle = pipe.fileHandleForReading

        // Buffer to accumulate lines for a complete JSON object
        // The output is pretty-printed, so we need to buffer until we have a complete object
        var jsonBuffer: [String] = []
        var braceDepth = 0

        // Read the output asynchronously
        for try await line in handle.tiltBytes.lines {
            // Skip empty lines when not inside an object
            if line.isEmpty && braceDepth == 0 {
                continue
            }

            // Add line to buffer
            jsonBuffer.append(line)

            // Count braces to track JSON object depth
            for char in line {
                if char == "{" {
                    braceDepth += 1
                } else if char == "}" {
                    braceDepth -= 1
                }
            }

            // When we return to depth 0, we have a complete JSON object
            if braceDepth == 0 && !jsonBuffer.isEmpty {
                let jsonString = jsonBuffer.joined(separator: "\n")

                // Parse the complete JSON object
                do {
                    let data = Data(jsonString.utf8)
                    let resource = try JSONDecoder().decode(UIResource.self, from: data)
                    handleResourceUpdate(resource)
                } catch {
                    print("Failed to parse UIResource: \(error)")
                    print("JSON was: \(jsonString.prefix(200))...")
                }

                // Reset buffer for next object
                jsonBuffer.removeAll()
            }

            // Check if the task was cancelled
            if Task.isCancelled {
                break
            }
        }

        // Process exited
        if !Task.isCancelled {
            // Only consider this an error if we weren't cancelled
            throw NSError(
                domain: "TiltClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "tilt process exited unexpectedly"]
            )
        }
    }

    // MARK: - Event Handling

    /// Process a UIResource update
    private func handleResourceUpdate(_ resource: UIResource) {
        let resourceName = resource.metadata.name

        // Update our local cache
        resources[resourceName] = resource

        // Recalculate and emit the aggregated status
        emitStatus()
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

        // Notify on the main thread
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionStateChange?(newState)
        }
    }
}

// MARK: - Extensions

extension FileHandle {
    /// AsyncSequence that yields lines from the file handle
    var tiltBytes: TiltAsyncBytes {
        TiltAsyncBytes(fileHandle: self)
    }
}

/// AsyncSequence that reads bytes from a FileHandle
struct TiltAsyncBytes: AsyncSequence {
    typealias Element = UInt8

    let fileHandle: FileHandle

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(fileHandle: fileHandle)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let fileHandle: FileHandle
        var buffer = Data()

        mutating func next() async throws -> UInt8? {
            // Read more data if buffer is empty
            if buffer.isEmpty {
                let data = fileHandle.availableData
                if data.isEmpty {
                    return nil
                }
                buffer = data
            }

            // Return the next byte
            let byte = buffer.removeFirst()
            return byte
        }
    }
}

/// Extension to split async bytes into lines
extension AsyncSequence where Element == UInt8 {
    var lines: AsyncLineSequence<Self> {
        AsyncLineSequence(base: self)
    }
}

struct AsyncLineSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String

    let base: Base

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        var buffer = Data()

        mutating func next() async throws -> String? {
            while true {
                // Try to get the next byte
                guard let byte = try await base.next() else {
                    // No more data - return any remaining buffer as a line
                    if buffer.isEmpty {
                        return nil
                    }
                    let line = String(data: buffer, encoding: .utf8) ?? ""
                    buffer.removeAll()
                    return line.isEmpty ? nil : line
                }

                // Check for newline
                if byte == UInt8(ascii: "\n") {
                    // Found a complete line
                    let line = String(data: buffer, encoding: .utf8) ?? ""
                    buffer.removeAll()
                    return line
                } else if byte == UInt8(ascii: "\r") {
                    // Skip carriage return
                    continue
                } else {
                    // Add to buffer
                    buffer.append(byte)
                }
            }
        }
    }
}
