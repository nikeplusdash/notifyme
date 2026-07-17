import Foundation

/// Two sources. **Hooks say what a session is doing; `claude agents` says who it is.**
///
/// ## Hooks own status
///
/// Hooks fire from Claude Code's own execution loop — `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
/// `Stop`. If a tool is running, `PreToolUse` fired. There is no daemon, no bridge, no network, and
/// nothing in between that can go stale. They also establish that a session **exists**, the instant it
/// does anything at all.
///
/// What they cannot give is identity: no human `name`, no real `startedAt`, and nothing whatsoever about
/// a session that has not acted since this app launched.
///
/// ## `claude agents --json` owns identity
///
/// Claude Code's own view of its sessions: `sessionId`, `cwd`, `name`, `startedAt`, `kind`, and — the
/// reason it is indispensable — the sessions that have **no process at all**. A background agent that
/// finishes its turn and waits for your reply *exits*. It keeps its conversation and its `blocked`
/// state, and it loses its pid. Nothing else on this machine can see it: no process, no registry file,
/// and no hook that will ever fire for it again. Three of them sat blocked on this user for a fortnight,
/// entirely invisible.
///
/// It is polled, so it is not instant — which is exactly why hooks establish existence and it does not.
///
/// ## What used to be here, and why it is gone
///
/// There was a third source: `RegistrySource`, watching `~/.claude/sessions/<pid>.json`. It was five
/// hundred and seventy-eight lines of file watchers, tombstones, retry logic and divergence detection,
/// all of it in service of making an **undocumented internal directory** trustworthy enough to draw a
/// picture from.
///
/// It offered nothing that these two do not, and its `status` field was actively dangerous: written by
/// Claude Code's remote-control bridge, it **freezes silently** when that bridge drops. Measured on a
/// live session, mid-work: `status=idle`, fourteen hours stale. We already refused to believe it.
///
/// What is left rests on two things Claude Code actually publishes — the hooks API and a CLI
/// subcommand — instead of on the shape of a scratch directory that can change on any update.
public final class FusedSource: SessionSource {

    private let hooks: HookSource
    private let agents: AgentsSource

    /// How often to re-merge with nothing having happened. See `start()`.
    ///
    /// The only thing this exists to catch is a background agent crossing the two-minute idle line that
    /// makes it *finished*. Checking every five seconds for a 120-second threshold woke the CPU 17,000
    /// times a day to learn nothing.
    private static let heartbeat: DispatchTimeInterval = .seconds(30)

    private let queue = DispatchQueue(label: "com.madebynikesh.NotifyMe.fused")
    private var snapshot: [String: Session] = [:]
    private var timer: DispatchSourceTimer?
    private var started = false

    /// Sessions we have already asked `AgentsSource` to identify.
    ///
    /// Without this, a session that hooks can see but `claude agents` never lists — for any reason —
    /// would request a refresh on *every* merge, for as long as it lived. Debouncing would floor that at
    /// one process launch every ten seconds: **worse than the fixed interval it replaced**. One ask per
    /// session, and only one.
    private var identityRequested: Set<String> = []

    public var onChange: (([SessionChange]) -> Void)?

    public init(hooks: HookSource = HookSource(), agents: AgentsSource = AgentsSource()) {
        self.hooks = hooks
        self.agents = agents
    }

    public var sessions: [Session] {
        queue.sync { snapshot.values.sorted { $0.startedAt < $1.startedAt } }
    }

    /// The agents CLI's health, because it owns the **set**. If it cannot answer, dormant sessions are
    /// invisible and nothing else will say so — which is precisely how a `PATH` bug hid every blocked
    /// agent while the app looked perfectly healthy.
    public var isHealthy: Bool { agents.isHealthy }

    public func start() {
        queue.sync {
            guard !started else { return }
            started = true
        }
        // Either source changing means the merged view may have changed. Recomputing is cheap — a
        // handful of sessions — and far safer than routing each source's diff through by hand.
        hooks.onChange = { [weak self] _ in self?.merge() }
        agents.onChange = { [weak self] _ in self?.merge() }
        hooks.start()
        agents.start()

        // A heartbeat, because one of the things that changes the merged view is **nothing happening**:
        // a background agent becomes finished purely by staying idle long enough, and no source will
        // ever announce that.
        //
        // **Not on `queue`.** `merge()` synchronises *onto* `queue`, so a timer firing on it would have
        // the handler `dispatch_sync` to the very serial queue it is already running on — an instant
        // deadlock that wedges the source and takes the app down with it. (Measured, the hard way: the
        // app died five seconds after every launch.)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.heartbeat, repeating: Self.heartbeat, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.merge() }
        timer.resume()
        self.timer = timer

        merge()
    }

    public func stop() {
        hooks.stop()
        agents.stop()
        queue.sync {
            timer?.cancel()
            timer = nil
            started = false
        }
    }

    // MARK: - Merge

    private func merge() {
        var changes: [SessionChange] = []
        var dirty = false
        var needsIdentity = false

        let identified = Set(agents.sessions.map(\.sessionId))

        queue.sync {
            var next: [String: Session] = [:]

            // 1. Hooks. Instant, and the only thing that can tell us a session exists *right now* —
            //    before the agents poll has come round. Identity-poor: no name, no real startedAt.
            for session in hooks.sessions {
                next[session.sessionId] = session

                // A session hooks can see and `claude agents` has never mentioned is a session that just
                // started. Its `name` is what the notification will say, so ask for it now rather than
                // wait out a two-minute interval a short session would never survive.
                if !identified.contains(session.sessionId),
                   identityRequested.insert(session.sessionId).inserted {
                    needsIdentity = true
                }
            }

            // Sessions that ended can be asked about again if their id ever returns.
            identityRequested.formIntersection(next.keys)

            // 2. Agents. The authoritative identity, and the only sight of a dormant session. It wins on
            //    *who*, and loses on *what they are doing* — its `status` for a live session is the same
            //    bridge-written field that freezes, so a hook always overrules it below.
            for var session in agents.sessions {
                if let hook = next[session.sessionId] {
                    session.status = hook.status
                    session.waitingFor = hook.waitingFor
                    session.statusChangedAt = hook.statusChangedAt
                }
                next[session.sessionId] = session
            }

            // 3. A finished background agent is dropped **entirely**. It has no terminal, nothing to go
            //    back to, and Claude Code never cleans up after it — so left alone, every agent ever run
            //    would accrete forever.
            //
            //    A **blocked** agent must never be caught by this: it is `.waiting`, not `.idle`,
            //    precisely because somebody has to answer it.
            let now = Date()
            for (id, session) in next where session.isFinished(asOf: now) {
                next[id] = nil
            }

            for (id, session) in next {
                guard let previous = snapshot[id] else {
                    changes.append(.appeared(session))
                    continue
                }
                if previous.status != session.status {
                    changes.append(.statusChanged(session: session, from: previous.status))
                }
            }
            for (id, last) in snapshot where next[id] == nil {
                changes.append(.disappeared(sessionId: id, last: last))
            }

            // A session can change without its *status* changing — and the one that does it constantly
            // is the **name**. Claude Code renames a session as the conversation reveals what it is
            // about, and that rewrite carries no status transition with it.
            //
            // Emitting a `.statusChanged` for it would be a lie, and would put a rename one bad `switch`
            // away from firing a "session finished" notification. So instead we notice the snapshot moved
            // at all, and fire `onChange` with whatever real transitions there were — possibly none.
            dirty = next != snapshot
            snapshot = next
        }

        // Outside the lock: `refresh()` synchronises onto the agents source's own queue.
        if needsIdentity { agents.refresh() }

        guard !changes.isEmpty || dirty else { return }

        // The app draws nothing now, so this log is the only way to see what it believes — and that
        // matters more than it sounds. `AgentsSource` was silently returning **127, command not found**
        // on every poll (a GUI app does not inherit your shell's PATH), and the dormant agents it exists
        // to find were invisible with nothing anywhere saying so. Every harness runs in a terminal, with
        // a full PATH, and proved a thing that was not true of the shipped app.
        let counts = snapshotCounts()
        Diagnostics.log("sessions: \(counts.total) (\(counts.waiting) waiting, \(counts.dormant) dormant)")

        DispatchQueue.main.async { [weak self] in self?.onChange?(changes) }
    }

    private func snapshotCounts() -> (total: Int, waiting: Int, dormant: Int) {
        queue.sync {
            (
                total: snapshot.count,
                waiting: snapshot.values.filter { $0.status == .waiting }.count,
                dormant: snapshot.values.filter { !$0.hasProcess }.count
            )
        }
    }
}
