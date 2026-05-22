import Foundation

/// UserDefaults adapter keyed by "CameraKit.CameraSettings" (07-settings.md §Persistence).
///
/// All members are static so the engine actor can call them from a detached Task
/// without violating strict concurrency (UserDefaults is Sendable in practice).
enum SettingsPersistence {
    static let key = "CameraKit.CameraSettings"

    static func save(_ settings: CameraSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    /// Load persisted CameraSettings, stripping `wbMode = .manual` plus the gain triple.
    ///
    /// Calibration is a per-session intent: each launch should start in continuous
    /// AWB so a stale manual lock from a prior session doesn't sticky-tint the
    /// preview. `.auto` and `.locked` round-trip unchanged because those are
    /// explicit user choices.
    static func load(defaults: UserDefaults = .standard) -> CameraSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard var settings = try? JSONDecoder().decode(CameraSettings.self, from: data) else {
            return nil
        }
        if settings.wbMode == .manual {
            settings.wbMode = nil
            settings.wbGainR = nil
            settings.wbGainG = nil
            settings.wbGainB = nil
        }
        return settings
    }

    // MARK: - Stage 04 — ProcessingParameters persistence
    // Key per architecture/07-settings.md §Persistence.
    // `.v2`: contrast convention changed from [0,2]/1.0-identity to
    // [-1,1]/0.0-identity. Bumping the key discards pre-change blobs so a stale
    // contrast=1.0 (old identity) isn't re-applied as max contrast under the new
    // scheme — users simply start at the new identity.
    static let processingKey = "CameraKit.ProcessingParameters.v2"

    static func saveProcessing(
        _ params: ProcessingParameters,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(params) else { return }
        defaults.set(data, forKey: processingKey)
    }

    static func loadProcessing(defaults: UserDefaults = .standard) -> ProcessingParameters? {
        guard let data = defaults.data(forKey: processingKey) else { return nil }
        return try? JSONDecoder().decode(ProcessingParameters.self, from: data)
    }
}
