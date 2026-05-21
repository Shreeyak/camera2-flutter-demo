import Foundation

/// Non-nil-field overlay merge per 07-settings.md §Merge model.
///
/// Types `CameraMode`, `WhiteBalanceMode`, `CameraSettings`, `ProcessingParameters` live in
/// `Capabilities.swift`; `WhiteBalanceGains`, `CameraPosition`, `TrackerQuality` in `FrameSet.swift`.
/// This file adds behavior (merging + coupling + Codable) without redeclaring types.
extension CameraSettings {

    /// Overlay every non-nil field from `self` onto `prior`.
    ///
    /// Nil fields in `self` preserve `prior`.
    public func merging(onto prior: CameraSettings) -> CameraSettings {
        var out = prior
        if let v = isoMode { out.isoMode = v }
        if let v = iso { out.iso = v }
        if let v = exposureMode { out.exposureMode = v }
        if let v = exposureTimeNs { out.exposureTimeNs = v }
        if let v = focusMode { out.focusMode = v }
        if let v = focusDistance { out.focusDistance = v }
        if let v = wbMode { out.wbMode = v }
        if let v = wbGainR { out.wbGainR = v }
        if let v = wbGainG { out.wbGainG = v }
        if let v = wbGainB { out.wbGainB = v }
        if let v = zoomRatio { out.zoomRatio = v }
        if let v = evCompensation { out.evCompensation = v }
        return out
    }
}

/// ISO + exposure coupling Rules 1/2/3 (07-settings.md §ISO + exposure coupling).
///
/// Rule 1: if isoMode == .manual, exposureMode must be .manual.
/// Rule 2: if exposureMode == .manual, isoMode must be .manual.
/// Rule 1/2 inverse: .auto on either side forces .auto on the other.
/// Rule 3: when transitioning a side to .manual without an explicit value, latch from the
///         most recent DeviceStateSnapshot. Pre-first-readback throws settingsConflict.
enum SettingsCoupling {

    static func apply(rules merged: CameraSettings, latched: DeviceStateSnapshot?) throws -> CameraSettings {
        var out = merged
        // Rule 1/2 propagation.
        switch (out.isoMode, out.exposureMode) {
        case (.auto, _), (_, .auto):
            out.isoMode = .auto
            out.exposureMode = .auto
        case (.manual, _), (_, .manual):
            out.isoMode = .manual
            out.exposureMode = .manual
        case (nil, nil):
            break
        }

        // Rule 3 — latch the inactive side from last sensor readback.
        if out.isoMode == .manual && out.iso == nil {
            guard let snap = latched else {
                throw EngineError.settingsConflict(reason: "Rule 3: manual ISO requested before first KVO readback")
            }
            out.iso = Int(snap.iso)
        }
        if out.exposureMode == .manual && out.exposureTimeNs == nil {
            guard let snap = latched else {
                throw EngineError.settingsConflict(
                    reason: "Rule 3: manual exposure requested before first KVO readback"
                )
            }
            out.exposureTimeNs = snap.exposureDurationNs
        }
        return out
    }

    /// Rule 4 — single-field manual promotion (iOS ISO/exposure coupling).
    ///
    /// iOS pins ISO and exposure together in one `setIsoExposureManual(durationNs:iso:)`
    /// call, so a request that sets exactly one side to `.manual` must pin both.
    /// Promote the unspecified side to `.manual` and clear its value (unless the
    /// request supplied it) so `apply`'s Rule 3 latches the current device
    /// reading — a smooth transition, instead of `merging`'s carried-over `.auto`
    /// coupling the request straight back to auto (measurements 2026-05-20 §1,
    /// case #4). A side already `.manual` in `merged` keeps its pinned value.
    ///
    /// Pure: takes the raw `request` (to read intent) and the post-`merging`
    /// `merged`; returns the adjusted settings to feed `apply`.
    static func promoteSingleFieldManual(
        request: CameraSettings,
        merged: CameraSettings
    ) -> CameraSettings {
        var out = merged
        if request.isoMode == .manual, request.exposureMode == nil, merged.exposureMode != .manual {
            out.exposureMode = .manual
            out.exposureTimeNs = request.exposureTimeNs  // nil → Rule 3 latches device value
        }
        if request.exposureMode == .manual, request.isoMode == nil, merged.isoMode != .manual {
            out.isoMode = .manual
            out.iso = request.iso  // nil → Rule 3 latches device value
        }
        return out
    }
}
