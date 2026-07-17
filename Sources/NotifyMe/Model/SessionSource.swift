import Foundation

/// A transition in the set of live sessions.
///
/// Emitted **only on real changes** — never on a plain re-read. This matters: the underlying files
/// are rewritten for reasons that aren't status changes, and firing a notification on every write
/// would make the app unusable.
public enum SessionChange: Equatable, Sendable {
    case appeared(Session)
    case statusChanged(session: Session, from: SessionStatus)
    // Keyed by `sessionId`, not pid: a dormant background agent has no pid to be identified by, and
    // it is exactly the kind of session that can appear and disappear from the list.
    case disappeared(sessionId: String, last: Session)
}

/// Where session state comes from.
///
/// Two implementations, and neither is sufficient alone:
///
/// - **`HookSource`** watches an event directory populated by hooks installed into
///   `~/.claude/settings.json`. Documented API, event-driven, nothing in between that can go stale —
///   and it establishes that a session *exists* the instant it does anything. But it carries no `name`
///   and no `startedAt`, and it is deaf to a session that has not acted since this app launched.
///
/// - **`AgentsSource`** shells out to `claude agents --json`, Claude Code's own view of its sessions.
///   Identity, retroactively and completely — including the sessions that have **no process at all**,
///   which nothing else on the machine can see. But it is polled, so it is never instant.
///
/// `FusedSource` combines them, and is what the app actually uses.
///
/// Everything downstream consumes `Session` and does not care which source produced it.
public protocol SessionSource: AnyObject {

    /// Current live sessions, ordered by `startedAt` — stable, so a diff against the previous set is
    /// meaningful rather than an artefact of dictionary ordering.
    var sessions: [Session] { get }

    /// Called on the **main queue** with a batch of transitions.
    var onChange: (([SessionChange]) -> Void)? { get set }

    /// Whether this source can actually see sessions on this machine right now.
    ///
    /// A source is unhealthy when it cannot see sessions that are demonstrably there. It matters
    /// because the failure is otherwise *silent*: an `AgentsSource` that cannot find the `claude`
    /// binary returns an empty list, and an app with nothing to say looks exactly like an app with
    /// nothing to report.
    var isHealthy: Bool { get }

    func start()
    func stop()
}

/// Are there interactive `claude` sessions running that a source ought to be seeing?
///
/// Used to distinguish "genuinely no sessions" from "the source is broken" — the difference between
/// an empty menu bar that's correct and one that's lying.
public enum ProcessProbe {

    /// Subcommands that run under the `claude` binary but are **not** interactive sessions.
    ///
    /// Claude Code spawns a background daemon and pty helpers that share the binary name, so
    /// `pgrep -x claude` reports them alongside real sessions. Counting them would fire a spurious
    /// "source is degraded" warning whenever the registry is legitimately empty but the daemon
    /// happens to be alive.
    ///
    /// They come in **two shapes**, and both must be filtered — observed live:
    ///
    ///     /Users/x/.local/bin/claude daemon run --origin transient --spawned-by {...}   <- subcommand
    ///     claude bg-pty-host --bg-pty-host /tmp/cc-daemon-501/.../f01.pty.sock          <- subcommand
    ///     claude bg-spare --bg-spare /tmp/cc-daemon-501/.../f01.claim.sock              <- subcommand
    ///     .../ClaudeCode.app/Contents/MacOS/claude --bg-pty-host ...                    <- FLAG, no subcommand
    ///
    /// That last one is why filtering on the leading subcommand alone is not enough.
    private static let helperSubcommands: Set<String> = [
        "daemon", "bg-pty-host", "bg-spare", "mcp", "install", "update", "doctor",
    ]

    /// Claude Code runs under several executable paths, and **only some of them are named `claude`**:
    ///
    ///     claude                                              bare, off PATH
    ///     /Users/x/.local/bin/claude                          the launcher
    ///     /Users/x/.local/share/claude/ClaudeCode.app/…/claude
    ///     /Users/x/.local/share/claude/versions/2.1.208       <- basename is a VERSION NUMBER
    ///
    /// That last one is what a **background agent job** runs as. Matching on the basename alone made
    /// every background job invisible to the probe — which, combined with the registry's `kind: "bg"`
    /// filter, is how a session that was actively working came to be missing from the menu bar
    /// entirely while its idle parent sat there reporting "done".
    private static func isClaudeExecutable(_ path: String) -> Bool {
        if (path as NSString).lastPathComponent == "claude" { return true }
        return path.contains("/claude/versions/")
    }

    /// A real session's argv is bare `claude`, optionally with flags (`--resume`, `--session-id`).
    /// Every helper carries either a leading bare subcommand or a `--bg-*` flag.
    static func isSessionArgv(_ args: [String]) -> Bool {
        if let first = args.first, !first.hasPrefix("-"), helperSubcommands.contains(first) {
            return false
        }
        if args.contains(where: { $0.hasPrefix("--bg-") }) { return false }
        return true
    }

    public static func liveClaudePIDs() -> Set<pid_t> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid=,args="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        var pids = Set<pid_t>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            var fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let pidField = fields.first, let pid = pid_t(pidField) else { continue }
            fields.removeFirst()
            guard let exec = fields.first else { continue }

            guard isClaudeExecutable(exec) else { continue }

            guard isSessionArgv(Array(fields.dropFirst())) else { continue }
            pids.insert(pid)
        }
        return pids
    }
}
