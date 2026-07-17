import AppKit

/// NotifyMe — tells you when a Claude Code session finishes, or needs you.
///
/// That is the whole app. It draws nothing, and it has one setting.
///
///     SessionSource ──onChange──▶ Notifier ──click──▶ Teleporter
///     (Registry/)                 (Notify/)           (Teleport/)
///
///     StatusItemController ──▶ launch at login · notifications · quit
///     (UI/)
///
/// The two halves do not talk to each other. The menu bar item knows nothing about sessions — it is an
/// icon and three switches — and the session pipeline knows nothing about the menu bar. It used to be
/// one path, because the bar was a live picture of every session and a click on a circle teleported to
/// it. The picture is gone: it answered a question the notification already answers, and it answered it
/// somewhere you had to remember to look.
///
/// Teleport survives because a notification you can *click through to the session* is worth far more
/// than one you can only read.
///
/// ## Where sessions come from
///
/// `FusedSource`, and each of its three inputs is there because the other two are blind to something:
///
/// - **the registry** (`~/.claude/sessions/`) knows every session with a live process, instantly — but
///   its `status` field is written by Claude Code's remote-control bridge and **freezes silently** when
///   that bridge drops. Measured at fourteen hours stale, still cheerfully reporting `idle`.
/// - **hooks** report what a session is actually *doing*, event-driven, with nothing in between to go
///   stale — but they only ever fire for a session that has a process.
/// - **`claude agents --json`** is the only thing that can see a session with **no process at all**: a
///   background agent that finished its turn, exited, and is sitting on your reply. Three of those were
///   blocked on this user for a fortnight, entirely invisible.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var source: (any SessionSource)?
    private var statusItem: StatusItemController?
    private var notifier: Notifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController()
        let sessions = FusedSource()
        let teleporter = Teleporter()
        let notifier = Notifier(teleporter: teleporter)

        notifier.requestAuthorization()
        controller.onQuit = { NSApp.terminate(nil) }

        // The source owns the diffing and emits only real transitions — never a bare re-read — so the
        // notifier can trust every change it is handed. (Session files get rewritten for reasons that
        // are not status changes; notifying on writes would fire a false "session finished" every time
        // one was renamed mid-conversation.)
        sessions.onChange = { changes in notifier.handle(changes) }
        sessions.start()

        if !sessions.isHealthy {
            NSLog("[NotifyMe] source UNHEALTHY — claude processes are running that it cannot see")
        }

        self.source = sessions
        self.statusItem = controller
        self.notifier = notifier
    }

    func applicationWillTerminate(_ notification: Notification) {
        source?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory = menu bar only: no Dock icon, no app menu of its own.
app.setActivationPolicy(.accessory)
app.run()
