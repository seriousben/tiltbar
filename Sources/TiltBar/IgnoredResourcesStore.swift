import Foundation

/// Manages the set of ignored failed resource names, persisted via UserDefaults.
///
/// When a user "ignores" a failed resource, it no longer counts toward the error
/// count in the status bar and is shown in a separate "Ignored" menu section
/// instead of the "Failures" section. Ignored resources are automatically removed
/// when they recover to a non-error state.
class IgnoredResourcesStore {
    private let userDefaultsKey = "ignoredFailedResources"

    /// Current set of ignored resource names
    private(set) var ignoredResources: Set<String>

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? []
        ignoredResources = Set(stored)
    }

    /// Mark a resource as ignored
    func ignore(_ resourceName: String) {
        ignoredResources.insert(resourceName)
        persist()
    }

    /// Remove a resource from the ignored set
    func unignore(_ resourceName: String) {
        ignoredResources.remove(resourceName)
        persist()
    }

    /// Check if a resource is currently ignored
    func isIgnored(_ resourceName: String) -> Bool {
        ignoredResources.contains(resourceName)
    }

    /// Remove ignored entries for resources that are no longer failing.
    /// Called when the failures list updates so that recovered resources
    /// don't stay in the ignored set forever.
    func removeRecovered(currentFailureNames: Set<String>) {
        let toRemove = ignoredResources.subtracting(currentFailureNames)
        if !toRemove.isEmpty {
            ignoredResources.subtract(toRemove)
            persist()
        }
    }

    private func persist() {
        UserDefaults.standard.set(Array(ignoredResources), forKey: userDefaultsKey)
    }
}
