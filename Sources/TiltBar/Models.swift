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
    var summary: String {
        var parts: [String] = []
        if inProgress > 0 { parts.append("\(inProgress) in progress") }
        if success > 0 { parts.append("\(success) ok") }
        if warning > 0 { parts.append("\(warning) warnings") }
        if error > 0 { parts.append("\(error) errors") }
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

// MARK: - Helper Extensions

extension UIResource {
    /// Determines the status of this resource based on its current state
    func determineStatus() -> ResourceStatusType {
        guard let status = status else {
            return .unknown
        }

        // Check updateStatus first (most authoritative)
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

        // If currently building, it's in progress
        if status.currentBuild != nil {
            return .inProgress
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
