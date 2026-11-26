import Foundation

/// Preferences live in a domain named after the bundle identifier, and the
/// first previews shipped under a placeholder. Move the settings a person
/// already made into the current domain once, before anything reads them.
enum PreferenceMigration {
    static let legacyIdentifier = "local.desktoplink.control"

    /// Every key the app reads or writes. Anything else in the old domain is
    /// left behind on purpose: Unknown keys are not ours to carry.
    static let keys = [
        "automaticClipboard", "desktopActualSizeByPeer", "desktopModesByPeer",
        "durableTransferPeers", "foxNotifications", "foxShowsAgents", "foxShowsJobs",
        "initialLinuxPeer", "lastDesktopHost", "lastLinuxProjects", "linuxPeers",
        "pendingJobStarts", "receivingLinuxPeer", "selectedLinuxPeer",
        "transferFolders", "transferVolumes",
    ]

    /// Copies the allowlisted keys the current domain is missing. A key the
    /// current domain already holds is never overwritten, so running this
    /// twice, or after someone changed a setting, cannot undo their choice.
    static func run(defaults: UserDefaults = .standard, legacy: String = legacyIdentifier) {
        guard let previous = UserDefaults(suiteName: legacy) else { return }
        var moved = false
        for key in keys where defaults.object(forKey: key) == nil {
            guard let value = previous.object(forKey: key) else { continue }
            defaults.set(value, forKey: key)
            moved = true
        }
        if moved { defaults.synchronize() }
    }
}
