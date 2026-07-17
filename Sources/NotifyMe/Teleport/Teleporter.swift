import AppKit
import Foundation

// `Diagnostics` used to live here. It now sits at the top level — see Diagnostics.swift for why.

/// Brings the terminal owning a session to the front, focused on its exact tab.
///
/// Three tiers, by what the host is actually capable of:
///
/// 1. **VS Code family** — one `POST /focus` to the companion extension. The owning window raises
///    itself *and* selects the tab. Process ancestry cannot identify a VS Code window (the pty host
///    is one process shared by every window), so asking all of them and letting the owner answer is
///    not a shortcut, it is the only mechanism that exists.
/// 2. **Terminal.app / iTerm2** — AppleScript, matching the session's tty against each tab's. Exact,
///    no extension required.
/// 3. **Everything else** (Ghostty, Warp, kitty) — `NSRunningApplication.activate()`. App-level
///    only; there is no tab to select from out here.
///
/// Nothing in here runs on the caller's thread, and nothing in here can hang: the bridge is on a
/// watchdog, every subprocess is on a timeout, and a missing host degrades to doing nothing.
public final class Teleporter {

    /// Shared with `Notifier` so a notification and its click-through resolve the same host once —
    /// and so a *dead* session still resolves, from cache, after `ps` has forgotten it.
    public let hostResolver: HostResolver

    /// Exposed because `Notifier` needs it too: "is the user already looking at this session?" is a
    /// question only the owning VS Code window can answer, and this is the thing that can ask it.
    public let bridge: VSCodeBridge
    private let work = DispatchQueue(label: "com.madebynikesh.NotifyMe.teleport", qos: .userInitiated)

    /// `code --status` costs a second. Cache it briefly so a burst of teleports (or a user clicking
    /// around a menu) doesn't pay for it repeatedly.
    private let statusLock = NSLock()
    private var openFolders: (names: Set<String>, at: Date)?
    private let openFoldersTTL: TimeInterval = 10

    public init() {
        self.hostResolver = HostResolver()
        self.bridge = VSCodeBridge()
    }

    /// Bring the terminal owning this session to the front, focused on its exact tab.
    public func teleport(to session: Session) {
        work.async { [weak self] in self?.perform(session) }
    }

    // MARK: - Dispatch by host

    private func perform(_ session: Session) {
        // **No process at all.** A dormant background agent: it finished its turn, exited, and is
        // sitting on your reply. There is no window to raise and no tab to focus, because nothing is
        // running — so a terminal has to be *created* rather than found. This is the only way to reach
        // these sessions, and until now the app could not even see them.
        guard session.hasProcess else {
            openAgentView(for: session)
            return
        }

        let resolved = hostResolver.resolve(session)

        guard let host = resolved.host else {
            // A live process with no GUI host: a background agent still running under Claude Code's
            // daemon, or tmux, ssh, a launchd-detached shell. There is a process, but no window owns it.
            //
            // Take the user to the *project* instead. It is not the session, but it is where the
            // session's work is landing, and it beats a click that does nothing — which is what this
            // used to be.
            Diagnostics.log("\(session.displayName): no GUI host — raising its project instead")
            for cli in ["/usr/local/bin/code", "/opt/homebrew/bin/code"] where FileManager.default.isExecutableFile(atPath: cli) {
                if raiseWindow(holding: session.cwd, cli: cli) { return }
            }
            return
        }

        Diagnostics.log(
            "\(session.displayName) → \(host.name) [\(host.kind)] shell=\(resolved.shellPID.map(String.init) ?? "?") tty=\(resolved.tty ?? "none")"
        )

        switch host.kind {
        case .vscodeFamily:
            teleportVSCode(session, resolved, host)
        case .terminalApp:
            if !focusTerminalApp(tty: resolved.tty) { activate(host) }
        case .iTerm2:
            if !focusITerm2(tty: resolved.tty) { activate(host) }
        case .other:
            activate(host)
        }
    }

    // MARK: - Tier 1: VS Code family

    private func teleportVSCode(_ session: Session, _ resolved: ResolvedHost, _ host: TerminalHost) {
        bridge.focus(
            shellPID: resolved.shellPID,
            ancestorPIDs: resolved.bridgeCandidatePIDs,
            preferredWorkspace: session.cwd
        ) { [weak self] result in
            guard let self else { return }

            if let result {
                Diagnostics.log(
                    "bridge: window on :\(result.port) claimed it (matched pid \(result.matchedPID.map(String.init) ?? "?"), windowRaised=\(result.windowRaised))"
                )

                // **Always activate. Do not trust `windowRaised`.**
                //
                // The extension calls `workbench.action.focusWindow`, which reaches Electron's
                // `app.focus({ steal: true })`, and it returns `windowRaised: true` when that command
                // does not throw. It throws either way — because **macOS does not let a background app
                // raise itself**, and no Electron flag changes that. So `windowRaised: true` means
                // "the command ran", not "the window came forward", and those are very different
                // things. Measured: the bridge reported `windowRaised=true` and Finder stayed
                // frontmost. The user clicked the notification and nothing happened.
                //
                // The division of labour is: **the extension owns the tab, we own the foreground.**
                // It selects the right terminal inside its window and makes that window key — which it
                // *can* do, being in-process — and then this raises the application, which only an
                // outside process with activation rights can do. Both halves are necessary and neither
                // is sufficient.
                //
                // Order matters: the bridge runs first, so the correct window is already the app's key
                // window by the time we bring the app forward. Activating first would raise whatever
                // window was last focused — a different project — and then swap it out.
                self.activate(host)
                return
            }

            // No window claimed the session: the extension isn't installed, hasn't reloaded, or this
            // terminal genuinely isn't in any window's list.
            //
            // Go **straight to the folder**. `code -r <cwd>` raises VS Code *and* focuses the window
            // holding that folder, in one move.
            //
            // It used to `activate(host)` first and then correct itself, which is what the user saw:
            // VS Code comes forward showing whatever window was last focused — a different project —
            // and then jumps to the right one. Two moves where the first one is wrong reads as a bug
            // even when the end state is correct. One right move beats it every time.
            Diagnostics.log("bridge: no window claimed \(session.displayName) — falling back")
            if !self.raiseWindow(holding: session.cwd, cli: host.cliPath) {
                // Nothing holds the folder, so there is no window to raise. App-level activation is
                // the honest degradation — and now it is the *only* thing that happens, so there is
                // no wrong window flashing past on the way.
                self.activate(host)
            }
        }
    }

    /// Focus the VS Code window that already has this folder open. Returns whether it did.
    ///
    /// This both raises VS Code and selects the right window, so the caller needs nothing before it.
    ///
    /// **Guarded on purpose.** `code -r` is `--reuse-window`: when a window *does* hold the folder it
    /// focuses that window, which is what we want — but when *no* window holds it, it does not open a
    /// new one, it **replaces the last-active window's workspace**. Silently swapping the folder out
    /// from under an unrelated window is a rotten outcome for a gesture that means "bring my terminal
    /// forward". So we only spend the `-r` when we can see the folder is already open; otherwise we
    /// report failure and let the caller degrade to app-level activation.
    @discardableResult
    private func raiseWindow(holding cwd: String, cli: String?) -> Bool {
        guard let cli else { return false }
        let folder = (cwd as NSString).lastPathComponent
        guard openFolderNames(cli: cli).contains(folder) else {
            Diagnostics.log("no window holds \"\(folder)\" — skipping `-r` rather than hijacking one")
            return false
        }
        Diagnostics.log("raising window holding \(cwd) via `\((cli as NSString).lastPathComponent) -r`")
        Shell.launch(cli, ["-r", cwd])
        return true
    }

    /// Basenames of every folder currently open in a window, from `code --status`.
    private func openFolderNames(cli: String) -> Set<String> {
        statusLock.lock()
        if let cached = openFolders, Date().timeIntervalSince(cached.at) < openFoldersTTL {
            statusLock.unlock()
            return cached.names
        }
        statusLock.unlock()

        let (status, output) = Shell.run(cli, ["--status"], timeout: 8)
        guard status == 0 else { return [] }

        // `|  Folder (DataMap): 165 files`
        var names: Set<String> = []
        for line in output.split(separator: "\n") {
            guard let open = line.range(of: "Folder ("),
                let close = line[open.upperBound...].firstIndex(of: ")")
            else { continue }
            let name = String(line[open.upperBound..<close]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { names.insert(name) }
        }

        statusLock.lock()
        openFolders = (names, Date())
        statusLock.unlock()
        return names
    }

    // MARK: - Tier 2: Terminal.app / iTerm2, matched on tty

    private func focusTerminalApp(tty: String?) -> Bool {
        guard let tty else { return false }
        let script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (tty of t) is \(Shell.appleScriptLiteral(tty)) then
                                set selected of t to true
                                set index of w to 1
                                activate
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        return Shell.osascript(script) == "ok"
    }

    private func focusITerm2(tty: String?) -> Bool {
        guard let tty else { return false }
        let script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if (tty of s) is \(Shell.appleScriptLiteral(tty)) then
                                    select w
                                    select t
                                    select s
                                    activate
                                    return "ok"
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        return Shell.osascript(script) == "ok"
    }

    // MARK: - Tier 3: app-level

    /// Raise the host application. Safe to call as a belt-and-braces step after a window-level focus:
    /// by then the correct window is already the app's key window.
    ///
    /// **`.activateIgnoringOtherApps` is not optional here, deprecated or not.**
    ///
    /// Without it, `activate(options:)` on macOS 14+ is the *cooperative* API: it asks, and the system
    /// is entitled to decline when the requester isn't the active app and the current frontmost app
    /// hasn't yielded. This app is an `.accessory` whose entire input surface is a menu bar item —
    /// clicking one does not make it the active application. So it has no foreground to hand off, its
    /// polite request is declined, and the terminal the user just asked for never comes forward. The
    /// call succeeds and nothing happens, which is the worst way for it to fail.
    ///
    /// It is also not rude: the user clicked a circle *in order to* be taken somewhere. Taking the
    /// foreground is doing what they asked, not stealing anything.
    /// **No `.activateAllWindows`.** It brings *every* one of the app's windows forward in their
    /// current z-order, which is the opposite of the job: by the time we get here the bridge (or
    /// `code -r`) has already made the *one correct* window key, and raising the whole stack on top of
    /// it just buries it again under whatever was in front. Observed doing exactly that — a teleport
    /// that reported success and surfaced an unrelated window.
    ///
    /// Plain activation brings the app's key window forward, and the key window is the one we asked
    /// for. That is the entire trick.
    /// Open a terminal on a session that has **no process to focus**.
    ///
    /// `claude agents` is Claude Code's own view of its background agents, and `--cwd` scopes it to one
    /// project — so this lands you in a list containing the agent you actually clicked, ready to answer
    /// it. Unscoped, it lists every agent on the machine; that is how these sessions were discovered,
    /// and it is emphatically not what you want after clicking one specific circle.
    ///
    /// A **new** window every time, never `do script` into the frontmost one: hijacking a terminal the
    /// user is working in would be a far worse sin than an extra window.
    private func openAgentView(for session: Session) {
        Diagnostics.log("\(session.displayName): dormant, no process — opening `claude agents` in a terminal")

        // POSIX single-quoting. Everything inside '…' is literal except ' itself, which is closed,
        // escaped, and reopened. A project path with a space or an apostrophe in it must not become
        // a command.
        let quoted = "'" + session.cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "claude agents --cwd \(quoted)"

        // Then escape that for an AppleScript string literal — a different language with different
        // rules, and the only two characters it cares about here are \ and ".
        let literal = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let source = """
        tell application "Terminal"
            activate
            do script "\(literal)"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            Diagnostics.log("could not open Terminal: \(error.localizedDescription)")
        }
    }

    private func activate(_ host: TerminalHost) {
        guard let app = NSRunningApplication(processIdentifier: host.pid) else { return }
        DispatchQueue.main.async {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
