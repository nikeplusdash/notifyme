import Foundation

/// The state of a live Claude Code session.
///
/// Colours are attention-weighted: red is reserved for things that are actually wrong, so the menu
/// bar only shouts when the user is the blocker — not while Claude is happily working.
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    /// Claude is working. Calm; needs nothing from the user.
    case busy
    /// Blocked on the user — permission prompt, question. See `Session.waitingFor`.
    case waiting
    /// Turn finished.
    case idle
    /// A status string we don't recognise. Never drawn.
    ///
    /// Claude Code's binary contains `compacting`, `starting`, `error` and `exited` alongside the
    /// three we've observed live, and may add more. Unknown must always be survivable — but it earns
    /// no circle, no colour and no setting. See `Preferences.isVisible(_:)`.
    case unknown

    // There is deliberately no `crashed`.
    //
    // A dead session is simply *gone*: the reaper notices the process has died and drops it, the same
    // as a session that exited cleanly. It used to linger as a red circle for twenty seconds first,
    // on the theory that a death is worth seeing — but a state that only appears when a process is
    // `SIGKILL`ed is a state almost nobody ever sees, and it was buying a colour, a checkbox, a
    // duration setting and a notification rule with that rarity. Death is now indistinguishable from
    // exit, which is what it looks like from the menu bar anyway.
}

// `isFilled`, `attentionRank` and `badge(for:)` used to live here.
//
// All three answered the same question — *how should this status be DRAWN?* — and there is nothing
// left to draw. `isFilled` chose a solid circle over a hairline ring; `attentionRank` ordered a session
// list; `badge(for:)` picked which status the `+N` overflow badge should wear. The menu bar is one
// static icon now, so they described a picture that no longer exists.
//
// What they encoded is not lost, it moved: a session that wants you is one that *fires a notification*,
// which is a truer place for the idea to live than a fill rule.

/// One live Claude Code session.
///
/// Produced by a `SessionSource`; consumed by the UI, teleport and notifications.
///
/// Keyed by `pid`, which is also the **join key for teleport**: the terminal that owns this session
/// is the one whose shell process is this process's parent. Verified against both data sources —
/// the registry reports `pid` directly, and a hook's `$PPID` is the `claude` process itself.
public struct Session: Identifiable, Equatable, Sendable {

    /// Claude Code's own session UUID. **The primary key**, and the transcript's name at
    /// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`.
    ///
    /// This used to be keyed by `pid`, which was wrong in a way that defeated the entire app. A
    /// background agent that finishes its turn and sits waiting for your reply **exits its process**:
    /// it keeps its conversation, its name and its `blocked` state, and it loses its pid. Keyed by pid,
    /// such a session cannot be represented at all — so the tracker simply did not show it.
    ///
    /// Three of them were blocked on the user, for days, while the menu bar cheerfully displayed the
    /// sessions that were *working* and wanted nothing. The one thing this app exists to say, it was
    /// structurally incapable of saying.
    public let sessionId: String

    /// PID of the `claude` process, or **nil when the session has no live local process**.
    ///
    /// Nil is not an error and not a corpse — it is a *dormant* session, most often a background agent
    /// blocked on you. It has no terminal, so there is nowhere to teleport to; reaching it means
    /// **creating** a terminal (see `Teleporter`). Everything that walks the process tree — host
    /// resolution, liveness, the shell join for VS Code — needs a real pid and must ask for one.
    public let pid: pid_t?

    /// Working directory. Identity in v1; the grouping key for v2's per-directory pies.
    public let cwd: String

    public var status: SessionStatus

    /// Why the session is blocked — e.g. `"permission prompt"`. Only meaningful when
    /// `status == .waiting`. Nil from sources that can't explain the block.
    public var waitingFor: String?

    /// Human label from the source, e.g. `"datamap-a9"`. May be empty — prefer `displayName`.
    public var name: String

    public let startedAt: Date

    /// A **background agent job** rather than a session in a terminal — Claude Code's `kind: "bg"`.
    ///
    /// It is a real session doing real work, and it must be visible while it is doing it: hiding these
    /// is how a user came to watch a background agent grind for an hour while the bar showed nothing
    /// but its idle parent, reporting a cheerful green "done".
    ///
    /// But it differs from a terminal session in one way that matters, and that is what
    /// `isFinished(asOf:)` is for.
    public var isBackground: Bool = false

    /// When `status` last changed.
    ///
    /// **Not file mtime.** The registry rewrites a session's file on changes that aren't status
    /// changes — we watched one session's `name` get refined mid-conversation, bumping `updatedAt`
    /// while `statusUpdatedAt` stood still. Keying transitions on mtime would fire a spurious
    /// "session finished" notification every time that happens.
    public var statusChangedAt: Date

    public var id: String { sessionId }

    /// Is there a live process behind this session — something with a terminal we could take you to?
    ///
    /// False means the session is dormant: it exists, it may well be waiting on you, but clicking it
    /// cannot *focus* anything because there is nothing running to focus.
    public var hasProcess: Bool { pid != nil }

    public init(
        pid: pid_t?,
        sessionId: String,
        cwd: String,
        status: SessionStatus,
        waitingFor: String? = nil,
        name: String = "",
        isBackground: Bool = false,
        startedAt: Date,
        statusChangedAt: Date
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.status = status
        self.waitingFor = waitingFor
        self.name = name
        self.isBackground = isBackground
        self.startedAt = startedAt
        self.statusChangedAt = statusChangedAt
    }

    /// Basename of `cwd` — `"DataMap"`.
    public var directoryName: String {
        (cwd as NSString).lastPathComponent
    }

    /// What the user reads in menus and notifications.
    public var displayName: String {
        name.isEmpty ? directoryName : name
    }


    /// How long a background agent may sit idle before it counts as **finished**, and is dropped
    /// entirely — from the bar, and from the menu.
    ///
    /// **Not zero**, and that is the whole subtlety. A background job you are still *talking to* goes
    /// idle between turns: it has answered you and is waiting for your next message. Dropping it the
    /// instant it stops working would make it blink out of the bar after every single exchange.
    ///
    /// **Not long, either.** The agents this exists to remove had been sitting idle for five, seven,
    /// eight hours. Claude Code never cleans up a finished agent's registry entry, so left alone every
    /// background agent you have ever run accretes as a permanent green "done" — a wall of dots for
    /// work you finished days ago.
    ///
    /// Two minutes separates "between turns" from "dead" with room to spare in both directions.
    public static let finishedBackgroundGrace: TimeInterval = 120

    /// A background agent that has finished: it has no terminal, it will never do anything again, and
    /// nothing about it is worth a row in a menu.
    ///
    /// An idle *terminal* session is the opposite — the tab is open, the prompt is waiting, and a green
    /// "ready for you" is exactly right. That asymmetry is why this checks `isBackground`.
    public func isFinished(asOf now: Date = Date()) -> Bool {
        isBackground
            && status == .idle
            && now.timeIntervalSince(statusChangedAt) > Session.finishedBackgroundGrace
    }

    /// Is the `claude` process still alive? The registry does not reliably remove a session's file
    /// when the process is `SIGKILL`ed, so liveness must be probed, not trusted.
    ///
    /// A session with **no** pid is alive. It is dormant, not dead: a background agent that finished
    /// its turn, exited its process, and is sitting on your reply. Reaping it for want of a pid would
    /// delete precisely the sessions that need you — so liveness is only ever a question about a
    /// process that exists.
    public var isAlive: Bool {
        guard let pid else { return true }
        return Session.isAlive(pid: pid)
    }

    /// Liveness of a pid, zombies counted as dead.
    ///
    /// **Do not use `kill(pid, 0)` here.** A `SIGKILL`ed process whose parent has not yet `wait()`ed
    /// becomes a *zombie*: the pid entry survives, and `kill(pid, 0)` returns **0** for it. That made
    /// the reaper believe a killed session was still running — it stayed on the menu bar, coloured
    /// green, indefinitely claiming it had finished. Verified: `ps -o stat=` reports `Z` while
    /// `kill(pid, 0)` returns 0 with `errno == 0`.
    ///
    /// `sysctl(KERN_PROC_PID)` is the honest probe: it distinguishes "no such process" from "process
    /// exists but is a corpse".
    public static func isAlive(pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride

        let rc = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0)
        }

        // No such process at all.
        guard rc == 0, size > 0 else { return false }

        // The pid exists but has already exited and is awaiting reaping by its parent.
        return info.kp_proc.p_stat != SZOMB
    }
}
