import AppKit
import Foundation
import UserNotifications

/// Turns session transitions into notifications, and a click on one into a teleport.
///
/// Fires on **transitions**, never on states — `handle` is driven by `SessionChange`, so a session
/// that merely *is* idle produces nothing; a session that *became* idle produces "finished".
///
/// | transition        | preference        |
/// | ----------------- | ----------------- |
/// | `busy → waiting`  | `notifyOnWaiting` |
/// | `busy → idle`     | `notifyOnDone`    |
/// | `any → crashed`   | `notifyOnCrash`   |
///
/// `.disappeared` deliberately notifies nothing: a death already arrived as a transition *to*
/// `.crashed` from the reaper, and `.disappeared` is only the later drop after
/// `crashedLingerSeconds`. Notifying on both would double-fire every crash.
public final class Notifier: NSObject {

    private let teleporter: Teleporter
    private let work = DispatchQueue(label: "com.madebynikesh.NotifyMe.notify", qos: .utility)

    private let lock = NSLock()
    private var backend: NotificationBackend
    /// Sessions we've seen, so a notification click can still find one whose process is long gone.
    private var known: [String: Session] = [:]

    public init(teleporter: Teleporter) {
        self.teleporter = teleporter
        // Default to the backend that cannot fail. Upgraded below if we're in a real bundle.
        self.backend = OSAScriptBackend()
        super.init()

        // THE LANDMINE. `UNUserNotificationCenter.current()` does not *fail* outside a bundle, it
        // raises an Obj-C exception — uncatchable from Swift, so the process dies. A nil bundle
        // identifier is the tell: never touch the class without one.
        if Bundle.main.bundleIdentifier != nil {
            self.backend = UserNotificationsBackend(delegate: self)
        } else {
            Diagnostics.log("unbundled: UNUserNotificationCenter would trap — using osascript")
        }
        Diagnostics.log("notification backend: \(self.backend.name)")
    }

    /// Which path we ended up on — `UNUserNotificationCenter` or the `osascript` fallback.
    public var backendName: String {
        lock.lock()
        defer { lock.unlock() }
        return backend.name
    }

    /// Ask for permission, and work out whether `UNUserNotificationCenter` is usable at all.
    ///
    /// The subtlety worth spelling out: a **denied** app and a **broken** app fail
    /// `requestAuthorization` identically, both returning "Notifications are not allowed for this
    /// application". Treating that error alone as "broken" would mean a user who clicked *Don't
    /// Allow* got notifications anyway, via osascript, on the very next launch. So the error is not
    /// the discriminator — the resulting `authorizationStatus` is:
    ///
    /// - `.denied` — an answer, not a malfunction. Respect it and post nothing.
    /// - `.notDetermined` after a failed ask — the framework genuinely can't function here. Fall back.
    ///
    /// (Directly executing `Contents/MacOS/NotifyMe` instead of `open`ing the bundle also lands
    /// in `.denied`, silently and permanently, because macOS never shows the prompt to an app it
    /// didn't launch through LaunchServices. `make run` opens the bundle, which is why it works.)
    public func requestAuthorization() {
        guard let un = currentBackend as? UserNotificationsBackend else { return }

        un.requestAuthorization { [weak self] granted, error, status in
            guard let self else { return }

            switch status {
            case .denied:
                Diagnostics.log("notifications are denied for this app — respecting that, not routing around it")
            case .notDetermined where error != nil:
                Diagnostics.log(
                    "UNUserNotificationCenter unusable (\(error?.localizedDescription ?? "unknown")) — falling back to osascript"
                )
                self.lock.lock()
                self.backend = OSAScriptBackend()
                self.lock.unlock()
            default:
                Diagnostics.log("notifications authorized=\(granted) status=\(status.rawValue)")
            }
        }
    }

    /// Apply the `Preferences` rules to a batch of transitions and fire notifications.
    ///
    /// Called on the main queue. Everything expensive — resolving a session's host app costs a `ps`
    /// — is moved straight off it; only the frontmost-app read, which is cheap, happens inline.
    public func handle(_ changes: [SessionChange]) {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        work.async { [weak self] in
            self?.process(changes, frontmostPID: frontmostPID)
        }
    }

    // MARK: - Rules

    private func process(_ changes: [SessionChange], frontmostPID: pid_t?) {
        for change in changes {
            switch change {
            case .appeared(let session):
                remember(session)
                // Warm the host cache while the process still exists. If this session later dies,
                // `ps` will know nothing about it — but we'll still be able to suppress on, and
                // teleport to, the window it lived in.
                _ = teleporter.hostResolver.resolve(session)

            case .statusChanged(let session, let from):
                remember(session)
                evaluate(session, from: from, frontmostPID: frontmostPID)

            case .disappeared(_, let last):
                // No notification (see the type doc). Just keep the record alive so a click on the
                // crash notification we already posted can still teleport.
                remember(last)
            }
        }
    }

    private func evaluate(_ session: Session, from: SessionStatus, frontmostPID: pid_t?) {
        // One switch now, not two. "Tell me when it finishes" and "tell me when it's blocked" were never
        // really separable — a person who wants one wants the other, and a person who wants neither wants
        // the app quiet.
        guard Preferences.shared.notificationsEnabled else { return }

        let title: String
        let body: String

        // Only two events are worth interrupting a person for, and a death is not one of them: a dead
        // session simply disappears, the same as one that exited cleanly.
        switch (from, session.status) {
        case (.busy, .waiting):
            title = "\(label(session)) needs you"
            body = session.waitingFor ?? "Waiting for you"

        case (.busy, .idle):
            title = "\(label(session)) finished"
            // What it *said*, not where it lives. The cwd was already in the title, so the old body
            // repeated it and the notification carried no information at all — which is exactly what
            // made you open the terminal: not because you wanted to be there, but because the banner
            // refused to tell you what happened.
            //
            // Falls back to the path when there is no transcript to read (a session that finished
            // without ever speaking), because a body that says where beats a body that says nothing.
            body = Transcript.lastAssistantText(sessionId: session.sessionId, cwd: session.cwd)
                ?? session.cwd

        default:
            return
        }

        // Suppression is no longer a setting, it is just correct. Being told a session finished while
        // you are watching it finish is noise, and nobody was ever going to go and turn that off — it
        // was a checkbox whose only honest value was the default.
        isUserLookingAt(session, frontmostPID: frontmostPID) { [weak self] looking in
            guard let self else { return }
            if looking {
                Diagnostics.log("suppressed \"\(title)\" — you are looking straight at it")
                return
            }
            self.post(session, title: title, body: body)
        }
    }

    /// Is the user looking at **this session's terminal**, right now?
    ///
    /// This used to compare the host app's pid against the frontmost app's — which, for the app this
    /// was built for, was catastrophically wrong. **One VS Code process (pid 1334) hosts every
    /// session.** So "VS Code is frontmost" was true whenever the user was working, and every
    /// notification for every session — including "your session finished", the thing the app exists
    /// to say — was silently swallowed. The check was not merely imprecise; it inverted the feature.
    ///
    /// The question can only be answered by the window itself, so for VS Code we ask the bridge:
    /// which window has focus, and which terminal is active inside it. A match against this session's
    /// shell pid is the *only* thing that means "you are looking at it".
    ///
    /// Everything fails **open**. No bridge, no focused window, a stale port, an older extension —
    /// all mean "we cannot tell", and we notify. A spurious notification is a nuisance; a swallowed
    /// one is a broken feature.
    private func isUserLookingAt(
        _ session: Session,
        frontmostPID: pid_t?,
        completion: @escaping (Bool) -> Void
    ) {
        let resolved = teleporter.hostResolver.resolve(session)

        guard let host = resolved.host, host.pid == frontmostPID else {
            // The host app isn't even frontmost. Nothing else to check.
            completion(false)
            return
        }

        guard host.kind == .vscodeFamily, let shellPID = resolved.shellPID else {
            // A host with one window per session — the app being frontmost really does mean you are
            // looking at it.
            completion(true)
            return
        }

        teleporter.bridge.focusedTerminalShellPID { focused in
            completion(focused == shellPID)
        }
    }

    private func post(_ session: Session, title: String, body: String) {
        // Keyed on the transition itself, not on a UUID: if the same transition is somehow
        // delivered twice, the second notification replaces the first rather than stacking.
        let id = "\(session.sessionId).\(session.status.rawValue).\(Int(session.statusChangedAt.timeIntervalSince1970))"

        Diagnostics.log("notify [\(backendName)] \(title) — \(body)")
        var userInfo: [String: Any] = [
            // Carried so a click still works after the app restarts, when `known` is empty.
            // Teleport needs nothing more than these.
            "cwd": session.cwd,
            "sessionId": session.sessionId,
            "name": session.name,
        ]
        // Absent for a dormant background agent. Teleport reads it as "no process to focus" and opens
        // a terminal instead — so it must be genuinely missing, not zero.
        if let pid = session.pid { userInfo["pid"] = Int(pid) }
        currentBackend.post(id: id, title: title, body: body, userInfo: userInfo)
    }

    /// `DataMap · datamap-a9` when the source gave us a name, plain `DataMap` when it didn't.
    private func label(_ session: Session) -> String {
        let directory = session.directoryName
        guard !session.name.isEmpty, session.name != directory else { return directory }
        return "\(directory) · \(session.name)"
    }

    // MARK: - Session memory

    private func remember(_ session: Session) {
        lock.lock()
        known[session.sessionId] = session
        if known.count > 256 {
            // A menu bar app lives for weeks. Don't accumulate every session the machine ever ran.
            let oldest = known.values.sorted { $0.startedAt < $1.startedAt }.prefix(known.count - 128)
            for session in oldest { known.removeValue(forKey: session.sessionId) }
        }
        lock.unlock()
    }

    private var currentBackend: NotificationBackend {
        lock.lock()
        defer { lock.unlock() }
        return backend
    }

    fileprivate func session(forNotificationInfo info: [AnyHashable: Any]) -> Session? {
        // Keyed on `sessionId`, which every notification carries. It used to key on `pid` and bail if
        // it was missing — which would now silently drop every click on a dormant background agent,
        // the exact sessions this app was failing to surface in the first place.
        guard let sessionId = info["sessionId"] as? String, !sessionId.isEmpty else { return nil }

        lock.lock()
        let remembered = known[sessionId]
        lock.unlock()
        if let remembered { return remembered }

        // Delivered across an app restart, so `known` is empty. Rebuild the minimum teleport needs.
        // `pid` is genuinely absent for a dormant agent — nil means "no process to focus", and
        // `Teleporter` opens a terminal for it rather than trying to raise a window that isn't there.
        guard let cwd = info["cwd"] as? String else { return nil }
        return Session(
            pid: (info["pid"] as? Int).map(pid_t.init),
            sessionId: sessionId,
            cwd: cwd,
            status: .unknown,
            name: info["name"] as? String ?? "",
            startedAt: Date(),
            statusChangedAt: Date()
        )
    }
}

// MARK: - Click-through

extension Notifier: UNUserNotificationCenterDelegate {

    /// Show the banner even when we're the active app — with the menu open, we are.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// The whole point: click the notification, land in the terminal that raised it.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let session = session(forNotificationInfo: response.notification.request.content.userInfo)
        else { return }
        Diagnostics.log("notification clicked → teleporting to \(session.displayName)")
        teleporter.teleport(to: session)
    }
}

// MARK: - Backends

private protocol NotificationBackend: AnyObject {
    var name: String { get }
    func post(id: String, title: String, body: String, userInfo: [String: Any])
}

/// The real thing. Needs a properly formed, code-signed bundle — `make build` produces one — and to
/// have been launched *through LaunchServices*, which is what `open`ing the bundle does.
private final class UserNotificationsBackend: NotificationBackend {
    let name = "UNUserNotificationCenter"
    private let center = UNUserNotificationCenter.current()

    init(delegate: UNUserNotificationCenterDelegate) {
        center.delegate = delegate
    }

    /// Reports the settled `authorizationStatus` alongside the result, because the caller cannot
    /// tell "the user said no" from "this framework is broken" without it.
    func requestAuthorization(
        _ completion: @escaping (Bool, Error?, UNAuthorizationStatus) -> Void
    ) {
        center.requestAuthorization(options: [.alert, .sound]) { [center] granted, error in
            center.getNotificationSettings { settings in
                completion(granted, error, settings.authorizationStatus)
            }
        }
    }

    func post(id: String, title: String, body: String, userInfo: [String: Any]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Diagnostics.log("UN post failed: \(error.localizedDescription)") }
        }
    }
}

/// The escape hatch, for when `UNUserNotificationCenter` won't work — an unbundled binary (the test
/// harness) or a bundle macOS refuses to trust.
///
/// **Loses click-through.** `display notification` posts under osascript's own identity, so there is
/// nothing for us to receive a click on. The notification still appears and still says the right
/// thing; it just isn't a teleport button.
private final class OSAScriptBackend: NotificationBackend {
    let name = "osascript"

    func post(id: String, title: String, body: String, userInfo: [String: Any]) {
        let script = "display notification \(Shell.appleScriptLiteral(body)) "
            + "with title \(Shell.appleScriptLiteral(title))"
        DispatchQueue.global(qos: .utility).async {
            _ = Shell.osascript(script, timeout: 10)
        }
    }
}
