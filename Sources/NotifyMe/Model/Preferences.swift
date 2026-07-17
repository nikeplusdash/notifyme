import Foundation

/// The app has exactly one preference.
///
/// It used to have a dozen — four colours, a circle limit, an identity glyph, a per-status visibility
/// filter, and separate switches for "tell me when it finishes" and "tell me when it's blocked". Every
/// one of them existed to tune a *picture* of the sessions, and there is no picture any more. They went
/// with it.
///
/// Launch-at-login is **not** here, deliberately: `SMAppService` already records it, in a list the user
/// can see and change in System Settings. Keeping a second copy would mean keeping two records of one
/// fact, and the copy the user can't see would eventually contradict the one they can. See
/// `LaunchAtLogin`.
public final class Preferences {

    public static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private init() {
        migrate()
        prune()
        defaults.register(defaults: [Key.notificationsEnabled: true])
    }

    /// The whole of the app, in one switch. Off means it watches and says nothing.
    public var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notificationsEnabled) }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    private enum Key {
        static let notificationsEnabled = "notificationsEnabled"

        // Retired. Read exactly once, by `migrate()`, and never again.
        static let legacyNotifyOnDone = "notifyOnDone"
        static let legacyNotifyOnWaiting = "notifyOnWaiting"
    }

    /// The bundle id the app shipped under before this rename, back when it was called ClaudeTracker.
    ///
    /// `UserDefaults.standard` is keyed by bundle id, so an upgrading user's settings sit in this old
    /// domain, invisible to the new `com.madebynikesh.NotifyMe` one. `migrate()` reaches across to it
    /// exactly once so the single surviving preference carries forward — otherwise anyone who had
    /// deliberately turned notifications **off** would find them back on after the update, which is the
    /// one direction this must never fail in.
    private static let legacyBundleID = "dev.nikeshkumar.ClaudeTracker"

    /// Carry forward the one preference that survived, from wherever the user last set it.
    ///
    /// Two switches became one, so the question "were notifications on?" is answered by *either* of the
    /// old ones being on. And `UserDefaults.standard` is keyed by bundle id, so the pre-rename domain is
    /// checked too — otherwise a user who had deliberately turned notifications **off** would find them
    /// back on, which is the one direction this must never fail in.
    private func migrate() {
        guard defaults.object(forKey: Key.notificationsEnabled) == nil else { return }

        let legacy = defaults.persistentDomain(forName: Self.legacyBundleID) ?? [:]
        func previous(_ key: String) -> Bool? {
            (defaults.object(forKey: key) ?? legacy[key]) as? Bool
        }

        let done = previous(Key.legacyNotifyOnDone)
        let waiting = previous(Key.legacyNotifyOnWaiting)
        guard done != nil || waiting != nil else { return }

        let wanted = (done ?? true) || (waiting ?? true)
        defaults.set(wanted, forKey: Key.notificationsEnabled)
        Diagnostics.log("migrated notification preference: \(wanted)")
    }

    /// Delete settings the app no longer has any concept of.
    ///
    /// Every one of these tuned a picture of the sessions — the colours, the circle limit, the identity
    /// glyph, the per-status visibility filter — and there is no picture. Left behind they are not
    /// merely untidy: anyone reading this app's defaults would find keys implying features it does not
    /// have, and would reasonably wonder which of them were still doing something.
    ///
    /// Runs after `migrate()`, which is the last thing that will ever want to read them.
    private func prune() {
        let retired = [
            "showGlyph", "maxCircles", "visibleStatuses", "suppressWhenFocused",
            "notifyOnDone", "notifyOnWaiting", "notifyOnCrash", "crashedLingerSeconds",
            "color.busy", "color.waiting", "color.idle", "color.unknown", "color.crashed",
        ]
        let present = retired.filter { defaults.object(forKey: $0) != nil }
        guard !present.isEmpty else { return }
        present.forEach(defaults.removeObject(forKey:))
        Diagnostics.log("pruned \(present.count) retired preference(s)")
    }
}
