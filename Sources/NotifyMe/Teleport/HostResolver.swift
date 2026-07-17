import AppKit
import Foundation

/// Which family of terminal owns a session. Selects the teleport strategy.
public enum TerminalHostKind: Equatable, Sendable {
    /// VS Code, Insiders, VSCodium, Cursor, Windsurf. Tab-level focus via the companion extension.
    case vscodeFamily
    /// Terminal.app. Tab-level focus via AppleScript, matched on tty.
    case terminalApp
    /// iTerm2. Tab-level focus via AppleScript, matched on tty.
    case iTerm2
    /// Ghostty, Warp, kitty, … App-level activation only.
    case other
}

/// The GUI application that owns a session's terminal.
public struct TerminalHost: Equatable, Sendable {
    /// PID of the GUI application itself — *not* the pty host or the shell.
    public let pid: pid_t
    public let bundleIdentifier: String?
    public let name: String
    public let kind: TerminalHostKind
    /// `Contents/Resources/app/bin/<cli>` — `code`, `cursor`, … Only for `.vscodeFamily`.
    public let cliPath: String?
}

/// Everything teleport and notification-suppression need to know about where a session lives.
public struct ResolvedHost: Equatable, Sendable {
    public let sessionPID: pid_t

    /// Claude's **immediate parent** — the shell. This is the number VS Code reports as
    /// `Terminal.processId`, and so the join key for the bridge.
    public let shellPID: pid_t?

    /// Claude's ancestors, nearest-first: shell, pty host, application…
    ///
    /// Sent to the bridge purely to survive the wrapper/subshell case — a `claude` that isn't
    /// directly parented by the terminal's shell. It can **not** identify a VS Code *window*: the
    /// pty host is a single process shared by every window, so every session's chain converges on
    /// the same two pids.
    public let ancestorPIDs: [pid_t]

    /// `/dev/ttys003`. Nil when the session has no controlling tty. The join key for Terminal/iTerm2.
    public let tty: String?

    /// Nil when no GUI application owns the session — tmux, ssh, a launchd-detached shell.
    public let host: TerminalHost?

    /// The pids worth offering the bridge: claude's parent chain, stopping **below** the terminal's
    /// process host.
    ///
    /// A VS Code terminal's `processId` is always a *shell*. It is never the pty host
    /// (`Code Helper`) and never the app — those two are single processes shared by every window.
    /// Offering them therefore cannot produce a true match, only a false one, in which some
    /// unrelated window recognises a pid it shares with everybody and claims a session it doesn't
    /// own. So we send the wrapper chain and stop before the shared plumbing starts.
    ///
    /// Normal case `[shell, ptyHost, app]` → `[shell]`.
    /// Wrapper case `[wrapper, shell, ptyHost, app]` → `[wrapper, shell]`, which is the whole point
    /// of sending an ancestry at all: a `claude` that isn't directly parented by the terminal's shell.
    public var bridgeCandidatePIDs: [pid_t] {
        guard let host, let hostIndex = ancestorPIDs.firstIndex(of: host.pid) else {
            return ancestorPIDs
        }
        return Array(ancestorPIDs.prefix(max(1, hostIndex - 1)))
    }
}

/// Walks the process tree up from a `claude` pid to the GUI application that owns its terminal.
///
/// Results are **cached by pid**, which is what lets a *dead* session still teleport and still be
/// suppressed: once the process exits, `ps` knows nothing about it, but we remember where it lived.
public final class HostResolver {

    private let lock = NSLock()
    private var cache: [pid_t: ResolvedHost] = [:]

    public init() {}

    public func resolve(_ session: Session) -> ResolvedHost {
        // A dormant background agent has no process, so there is no parent chain to walk and no window
        // that owns it. Resolving "the terminal hosting pid nothing" is not a question with an answer —
        // and answering it wrongly is what would matter, because `Notifier` uses a resolved host to
        // decide you are *looking* at a session and swallow its notification. Nil host means it cannot
        // suppress, which is the right way to fail for a session that is blocked on you.
        guard let pid = session.pid else {
            return ResolvedHost(sessionPID: 0, shellPID: nil, ancestorPIDs: [], tty: nil, host: nil)
        }
        return resolve(pid: pid)
    }

    public func resolve(pid: pid_t) -> ResolvedHost {
        if let fresh = resolveUncached(pid: pid), fresh.host != nil {
            lock.lock()
            cache[pid] = fresh
            lock.unlock()
            return fresh
        }
        // Process is gone, or we couldn't find a GUI ancestor. A remembered answer beats nothing.
        lock.lock()
        let remembered = cache[pid]
        lock.unlock()
        return remembered
            ?? ResolvedHost(sessionPID: pid, shellPID: nil, ancestorPIDs: [], tty: nil, host: nil)
    }

    public func forget(pid: pid_t) {
        lock.lock()
        cache.removeValue(forKey: pid)
        lock.unlock()
    }

    // MARK: - The walk

    private func resolveUncached(pid: pid_t) -> ResolvedHost? {
        let table = ProcessTable.snapshot()
        guard let start = table[pid] else { return nil }

        var ancestors: [pid_t] = []
        var host: TerminalHost?

        var current = start.ppid
        var seen: Set<pid_t> = [pid]
        // Bounded: a corrupt table must not spin us forever.
        for _ in 0..<32 {
            guard current > 1, !seen.contains(current), table[current] != nil else { break }
            seen.insert(current)
            ancestors.append(current)

            // A GUI application is the first ancestor LaunchServices knows about. Everything
            // between claude and the app -- the shell, VS Code's `Code Helper` pty host, Terminal's
            // `login` -- answers nil here, which is exactly the discriminator we want.
            if host == nil, let app = NSRunningApplication(processIdentifier: current),
                app.activationPolicy != .prohibited {
                host = Self.classify(app)
            }

            current = table[current]?.ppid ?? 0
        }

        return ResolvedHost(
            sessionPID: pid,
            shellPID: ancestors.first,
            ancestorPIDs: ancestors,
            tty: Self.devicePath(for: start.tty),
            host: host
        )
    }

    private static func classify(_ app: NSRunningApplication) -> TerminalHost {
        let bundleID = app.bundleIdentifier
        let name = app.localizedName ?? bundleID ?? "pid \(app.processIdentifier)"
        let cli = app.bundleURL.flatMap(vscodeCLI(inBundleAt:))

        let kind: TerminalHostKind
        switch bundleID {
        case "com.apple.Terminal":
            kind = .terminalApp
        case "com.googlecode.iterm2":
            kind = .iTerm2
        default:
            // Structural, not a bundle-id allowlist: every VS Code fork (Cursor, Windsurf, VSCodium)
            // ships the same `Contents/Resources/app/bin/<cli>` layout, and their bundle ids are
            // opaque (Cursor's is a ToDesktop hash). Finding that CLI *is* the family test.
            kind = cli != nil ? .vscodeFamily : .other
        }

        return TerminalHost(
            pid: app.processIdentifier,
            bundleIdentifier: bundleID,
            name: name,
            kind: kind,
            cliPath: kind == .vscodeFamily ? cli : nil
        )
    }

    /// The `code`-style launcher inside a VS Code-family bundle, or nil if this isn't one.
    private static func vscodeCLI(inBundleAt bundle: URL) -> String? {
        let bin = bundle.appendingPathComponent("Contents/Resources/app/bin")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: bin.path) else { return nil }
        // `code` sits alongside `code-tunnel`; we want the launcher, never the tunnel.
        let candidates = entries.filter { !$0.hasSuffix("-tunnel") && !$0.hasPrefix(".") }.sorted()
        for entry in candidates {
            let path = bin.appendingPathComponent(entry).path
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// `ps` prints `ttys003`; AppleScript wants `/dev/ttys003`. `??` means no controlling tty.
    private static func devicePath(for tty: String?) -> String? {
        guard let tty, tty != "??", !tty.isEmpty else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
    }
}

// MARK: - Process table

/// One row of `ps`.
struct ProcRecord {
    let pid: pid_t
    let ppid: pid_t
    let tty: String?
    let command: String
}

enum ProcessTable {

    /// One `ps` for the whole tree, rather than one per level. Walking a chain of five costs a
    /// single spawn instead of five.
    static func snapshot() -> [pid_t: ProcRecord] {
        let (_, out) = Shell.run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,command="], timeout: 5)
        var table: [pid_t: ProcRecord] = [:]
        for line in out.split(separator: "\n") {
            guard let record = parse(String(line)) else { continue }
            table[record.pid] = record
        }
        return table
    }

    /// `  8835  8413 ttys003  claude` — the command is the tail, and it can contain spaces.
    static func parse(_ line: String) -> ProcRecord? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3,
            let pid = pid_t(fields[0]),
            let ppid = pid_t(fields[1])
        else { return nil }
        let tty = String(fields[2])
        let command = fields.dropFirst(3).joined(separator: " ")
        return ProcRecord(pid: pid, ppid: ppid, tty: tty, command: command)
    }
}
