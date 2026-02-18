import Foundation

// MARK: - Tilt UIResource

/// Represents a Tilt resource as returned by the Tilt API
///
/// UIResource is Tilt's main status object containing information about:
/// - Build history (recent builds with errors/warnings)
/// - Current build (if one is running)
/// - Runtime status (pod state for K8s resources)
/// - Update status (high-level resource state)
///
/// This is a simplified version containing only the fields we need.
/// For full schema, see: https://api.tilt.dev/interface/ui-resource-v1alpha1.html
struct UIResource: Codable {
    /// Standard Kubernetes metadata (name, namespace, etc.)
    let metadata: Metadata

    /// The status contains all the runtime information about the resource
    let status: UIResourceStatus?

    struct Metadata: Codable {
        /// The unique name of this resource
        let name: String
    }

    struct UIResourceStatus: Codable {
        /// Recent build history - we check the most recent for errors/warnings
        let buildHistory: [BuildRecord]?

        /// Information about the currently running build (if any)
        let currentBuild: CurrentBuild?

        /// High-level runtime state of the resource
        let runtimeStatus: String?

        /// High-level update status
        let updateStatus: String?

        struct BuildRecord: Codable {
            /// Non-empty if the build failed
            let error: String?

            /// List of warnings from this build
            let warnings: [String]?

            /// When the build started
            let startTime: String?

            /// When the build finished
            let finishTime: String?
        }

        struct CurrentBuild: Codable {
            /// When this build started
            let startTime: String?
        }

        /// Information about what this resource is waiting for
        let waiting: WaitingInfo?

        struct WaitingInfo: Codable {
            /// Resources this resource is waiting on
            let on: [WaitingOn]?

            /// Human-readable reason for waiting
            let reason: String?

            struct WaitingOn: Codable {
                /// The name of the resource being waited on
                let name: String?
            }
        }
    }
}

// MARK: - Aggregated Resource Status

/// Tracks the aggregated status of all resources
/// This is what we display in the status bar
struct ResourceStatus {
    /// Resources currently building or updating
    var inProgress: Int = 0

    /// Resources that are running successfully
    var success: Int = 0

    /// Resources with warnings
    var warning: Int = 0

    /// Resources with errors
    var error: Int = 0

    /// Total number of resources being tracked
    var total: Int {
        inProgress + success + warning + error
    }

    /// Returns a human-readable summary
    /// Order matches the status bar colors: red, yellow, gray, green
    var summary: String {
        var parts: [String] = []
        if error > 0 { parts.append("\(error) errors") }
        if warning > 0 { parts.append("\(warning) warnings") }
        if inProgress > 0 { parts.append("\(inProgress) pending") }
        if success > 0 { parts.append("\(success) ok") }
        return parts.isEmpty ? "No resources" : parts.joined(separator: ", ")
    }
}

// MARK: - Connection State

/// Represents the connection state to the Tilt server
enum ConnectionState {
    /// Not connected, will retry soon
    case disconnected

    /// Currently attempting to connect
    case connecting

    /// Successfully connected and receiving updates
    case connected

    /// Server appears to be down (connection refused, etc.)
    case serverDown

    var displayText: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .serverDown: return "Server Down"
        }
    }
}

// MARK: - Failure Tracking

/// Information about a resource failure for display in the menu
struct FailureInfo {
    /// The name of the resource that failed
    let resourceName: String

    /// The error message from the build
    let errorMessage: String

    /// When the failure occurred
    let timestamp: Date

    /// URL to view this resource in the Tilt web UI
    var webURL: String {
        "http://localhost:10350/r/\(resourceName)/overview"
    }

    /// Human-readable time since failure
    var timeAgo: String {
        let interval = Date().timeIntervalSince(timestamp)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

/// Information about a resource currently in progress for display in the menu
struct InProgressInfo {
    /// The name of the resource being built/updated
    let resourceName: String

    /// When the build/update started
    let startTime: Date

    /// Number of resources that depend on this resource (waiting for it)
    var dependentCount: Int = 0

    /// URL to view this resource in the Tilt web UI
    var webURL: String {
        "http://localhost:10350/r/\(resourceName)/overview"
    }

    /// Human-readable duration
    var duration: String {
        let interval = Date().timeIntervalSince(startTime)

        if interval < 60 {
            let seconds = Int(interval)
            return "\(seconds)s"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m \(Int(interval.truncatingRemainder(dividingBy: 60)))s"
        } else {
            let hours = Int(interval / 3600)
            let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
            return "\(hours)h \(minutes)m"
        }
    }
}

/// Information about a resource that is pending (not actively building)
struct PendingResourceInfo {
    /// The name of the pending resource
    let resourceName: String

    /// Names of resources it's waiting on (may be empty)
    let waitingOn: [String]

    /// The reason for waiting (e.g. "waiting-for-local")
    let reason: String?

    /// URL to view this resource in the Tilt web UI
    var webURL: String {
        "http://localhost:10350/r/\(resourceName)/overview"
    }

    /// Short detail: what it's waiting on, or the reason, or just "pending"
    var detail: String {
        if !waitingOn.isEmpty {
            if waitingOn.count == 1 {
                return waitingOn[0]
            }
            return "\(waitingOn.count) resources"
        }
        return reason ?? "pending"
    }
}

// MARK: - Helper Extensions

extension UIResource {
    /// Determines the status of this resource based on its current state
    func determineStatus() -> ResourceStatusType {
        guard let status = status else {
            return .unknown
        }

        // Check if currently building FIRST - takes precedence over everything
        // A resource that is actively rebuilding should always show as in-progress,
        // even if it previously failed
        if status.currentBuild != nil {
            return .inProgress
        }

        // Check updateStatus (most authoritative for non-building resources)
        if let updateStatus = status.updateStatus {
            switch updateStatus {
            case "error":
                return .error
            case "warning":
                return .warning
            case "in_progress", "pending":
                return .inProgress
            case "ok":
                // Continue to check other fields
                break
            default:
                break
            }
        }

        // Check most recent build for errors or warnings
        if let mostRecentBuild = status.buildHistory?.first {
            if let error = mostRecentBuild.error, !error.isEmpty {
                return .error
            }
            if let warnings = mostRecentBuild.warnings, !warnings.isEmpty {
                return .warning
            }
        }

        // Check runtime status for errors
        if let runtimeStatus = status.runtimeStatus {
            switch runtimeStatus {
            case "error":
                return .error
            case "warning":
                return .warning
            case "pending":
                return .inProgress
            default:
                break
            }
        }

        // Otherwise assume success
        return .success
    }
}

enum ResourceStatusType {
    case inProgress
    case success
    case warning
    case error
    case unknown
}
