import Foundation
import ServiceManagement

/// Start the app when the user logs in.
///
/// Backed by `SMAppService`, which is macOS's own login-items register — the same list that appears in
/// **System Settings → General → Login Items**. That matters more than it sounds: the old way (a
/// `LaunchAgent` plist, or the long-deprecated `SMLoginItemSetEnabled`) put the app somewhere the user
/// could not see and could not turn off, which is precisely the behaviour a menu-bar utility must never
/// have. Here, whatever the checkbox says, the user can always override it in System Settings — and if
/// they do, `isEnabled` reports *their* answer, not ours, because the system is the source of truth.
///
/// There is deliberately no `UserDefaults` copy of this. Two records of one fact drift apart, and the
/// one the user can see would lose.
enum LaunchAtLogin {

    /// Is the app registered to launch at login **right now**, according to the system?
    ///
    /// `.enabled` is the only status that means yes. `.requiresApproval` means macOS has it registered
    /// but the user has switched it off in System Settings — which is a *no*, and saying otherwise
    /// would leave a ticked checkbox next to an app that never starts.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Turn it on or off. Returns the state that actually took effect, which is not always the one
    /// asked for — registration can be refused, and a checkbox that lies about it is worse than one
    /// that refuses.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The common cause is an ad-hoc signature or a bundle outside /Applications, and there is
            // nothing to be done about either from in here. Report the truth and let the caller re-read
            // the system's answer rather than assume the write landed.
            Diagnostics.log("launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        return isEnabled
    }
}
