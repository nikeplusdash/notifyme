import Foundation

/// Reconstructs session state from Claude Code's **documented** hooks API.
///
/// This is the app's source of **truth about what a session is doing**, and there is no longer a
/// fallback behind it. It replaced one: `RegistrySource` read `~/.claude/sessions`, a directory Claude
/// Code never promised anyone, whose `status` field is written by the remote-control bridge and
/// **freezes silently** when that bridge drops — measured at fourteen hours stale on a session that was
/// mid-work. Hooks fire from Claude Code's own execution loop, so there is nothing in between to go
/// stale: if a tool is running, `PreToolUse` fired.
///
/// The trade is real:
///
/// - it **mutates the user's `settings.json`**, so it is opt-in (see `HookInstaller`);
/// - it only ever sees sessions that started **after** installation — there is no way to enumerate
///   what was already running;
/// - hooks carry no session `name`, so `Session.displayName` falls back to the cwd basename.
///
/// What it does get is a pid: the hook's `$PPID` *is* the `claude` process, which is the join key
/// teleport needs.
///
/// ## Deriving status from events
///
/// The hook stream is a sequence of edges, not states, so status is folded rather than read:
///
///     SessionStart      -> .idle      a session exists
///     UserPromptSubmit  -> .busy      the user asked for something
///     PreToolUse        -> .busy      a tool is about to run
///     Notification      -> .waiting   Claude is blocked on the user (the permission prompt)
///     PostToolUse       -> .busy      the tool ran, so the block cleared
///     Stop              -> .idle      the turn finished
///     SessionEnd        -> gone
public final class HookSource: SessionSource {

    private let eventsDirectory: URL

    private let queue = DispatchQueue(label: "com.claudetracker.hooks", qos: .utility)
    private let lock = NSLock()

    private var snapshot: [pid_t: Session] = [:]
    private var published: [Session] = []
    private var healthy = false

    private var dirSource: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var pendingScan: DispatchWorkItem?
    private var started = false

    private let reaper = Reaper()

    /// Cached interactive-pid probe, used to keep background agent jobs out of the menu bar.
    private var probedPIDs: Set<pid_t> = []
    private var lastProbe = Date.distantPast
    private static let probeInterval: TimeInterval = 1

    public init(eventsDirectory: URL = HookPaths.events) {
        self.eventsDirectory = eventsDirectory
    }

    deinit { teardown() }

    // MARK: - SessionSource

    public var onChange: (([SessionChange]) -> Void)?

    public var sessions: [Session] {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    /// Health here is about the plumbing, not the population.
    ///
    /// It deliberately does **not** ask "is `claude` running while I see nothing?", because for this
    /// source that is a perfectly legal state: hooks only fire for sessions started after they were
    /// installed, so a machine full of older sessions will correctly show nothing. Asking the process
    /// table would report a permanent, unfixable fault.
    ///
    /// What we can honestly check is whether the pipe is connected: are the hooks actually in
    /// `settings.json`, and is the drop-box there to receive them?
    public var isHealthy: Bool {
        lock.lock(); defer { lock.unlock() }
        return healthy
    }

    public func start() {
        queue.sync {
            guard !started else { return }
            started = true

            // Our own directory, not the user's config — creating it installs nothing.
            try? FileManager.default.createDirectory(
                at: eventsDirectory,
                withIntermediateDirectories: true
            )

            armWatch()
            drain()
            startTimer()
        }
    }

    public func stop() {
        queue.sync { teardown() }
    }

    private func teardown() {
        started = false
        pendingScan?.cancel(); pendingScan = nil
        timer?.cancel(); timer = nil
        dirSource?.cancel(); dirSource = nil
    }

    // MARK: - Watch

    /// A directory watch is sufficient here: the hook creates a **new file** per event and we delete it
    /// once consumed, so every change is a change to the directory's entry list. Nothing is ever
    /// rewritten in place — which is the trap that a directory watch would have missed, and did, when
    /// this app still watched session files that were rewritten under a stable inode.
    private func armWatch() {
        dirSource?.cancel()
        dirSource = nil

        let fd = open(eventsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return } // the poll timer keeps retrying

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self, let flags = self.dirSource?.data else { return }
            if flags.contains(.delete) || flags.contains(.rename) {
                self.armWatch()
            }
            self.scheduleDrain()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(
            deadline: .now() + Reaper.interval,
            repeating: Reaper.interval,
            leeway: .milliseconds(500)
        )
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func scheduleDrain(after delay: TimeInterval = 0.03) {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingScan = nil
            self.drain()
        }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func tick() {
        guard started else { return }

        drain() // backstop, in case a filesystem event was ever missed

        let changes = reaper.reap(snapshot: &snapshot)
        guard !changes.isEmpty else { return }
        publish(changes)
    }

    // MARK: - Drain

    /// Consume every pending event file, fold it into session state, and delete it.
    private func drain() {
        guard started else { return }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            armWatch()
            return
        }

        // A session's hooks are serialised by Claude Code — it blocks on each one — so per-session
        // file creation order is exactly event order. Across sessions the interleaving is arbitrary,
        // but those are independent state machines, so it doesn't matter. Sort by mtime (sub-second
        // on APFS) and break ties on the name, which carries a seconds stamp and the hook's pid.
        var files: [(url: URL, at: Date)] = []
        for url in entries where url.pathExtension == "json" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let at: Date = values?.contentModificationDate ?? Date.distantPast
            files.append((url: url, at: at))
        }
        files.sort { lhs, rhs in
            if lhs.at != rhs.at { return lhs.at < rhs.at }
            return lhs.url.lastPathComponent < rhs.url.lastPathComponent
        }

        guard !files.isEmpty else {
            refreshHealth()
            return
        }

        var changes: [SessionChange] = []

        for file in files {
            guard let data = try? Data(contentsOf: file.url) else { continue }
            guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
                // The hook renames its output into place, so a torn read shouldn't be possible. A
                // file we still can't parse is junk; bin it rather than retrying it forever.
                try? FileManager.default.removeItem(at: file.url)
                continue
            }

            apply(event, at: file.at, into: &changes)
            try? FileManager.default.removeItem(at: file.url)
        }

        publish(changes)
    }

    /// Fold one event into the snapshot.
    private func apply(_ event: HookEvent, at fileTime: Date, into changes: inout [SessionChange]) {
        let pid = event.pid
        guard pid > 0 else { return }

        let now = event.timestamp ?? fileTime
        let name = event.payload.event

        // Background agent jobs fire hooks too, and they have no terminal — a circle for one would
        // teleport nowhere. The registry discriminates them with `kind`, but the hook payload has no
        // such field, so we fall back to the process table, which tells the same story from argv.
        //
        // Fails **open**: if the probe comes back empty it is broken, not authoritative, and showing
        // an extra circle beats showing an empty menu bar.
        if snapshot[pid] == nil, name != "SessionEnd", !isInteractive(pid) { return }

        if name == "SessionEnd" {
            guard let last = snapshot.removeValue(forKey: pid) else { return }
            reaper.forget(pid)
            changes.append(.disappeared(sessionId: last.sessionId, last: last))
            return
        }

        // Nil means "no status change" — an event we don't model, *or* a `Notification` that turns out
        // to be the idle-60s timeout rather than a real block. Both must leave the session exactly as
        // it was.
        guard let status = Self.status(for: event) else { return }

        guard var session = snapshot[pid] else {
            // First we've heard of this pid. Normally that's `SessionStart`, but be forgiving: if we
            // came up mid-session, or missed an event, adopt it on whatever we saw first rather than
            // ignoring a session that demonstrably exists.
            let session = Session(
                pid: pid,
                sessionId: event.payload.sessionId ?? "",
                cwd: event.payload.cwd ?? "",
                status: status,
                waitingFor: waitingReason(for: event, status: status),
                // Hooks carry no name. `Session.displayName` falls back to the cwd basename.
                name: "",
                startedAt: now,
                statusChangedAt: now
            )
            snapshot[pid] = session
            changes.append(.appeared(session))
            return
        }

        session.waitingFor = waitingReason(for: event, status: status)
        if let cwd = event.payload.cwd, !cwd.isEmpty, session.cwd != cwd {
            // cwd is `let` on Session, so a genuine directory change means a new value object.
            session = Session(
                pid: session.pid,
                sessionId: session.sessionId.isEmpty
                    ? (event.payload.sessionId ?? "") : session.sessionId,
                cwd: cwd,
                status: session.status,
                waitingFor: session.waitingFor,
                name: session.name,
                startedAt: session.startedAt,
                statusChangedAt: session.statusChangedAt
            )
        }

        let from = session.status
        guard status != from else {
            // Same status as before. This is the transition bug in its hook-shaped form: a run of
            // PreToolUse/PostToolUse events is a stream of `.busy` that must produce exactly zero
            // change events, or every tool call would ping the user.
            snapshot[pid] = session
            return
        }

        session.status = status
        session.statusChangedAt = now
        snapshot[pid] = session
        changes.append(.statusChanged(session: session, from: from))
    }

    private func waitingReason(for event: HookEvent, status: SessionStatus) -> String? {
        guard status == .waiting else { return nil }
        let payload = event.payload
        let reason = payload.message ?? payload.reason
        return (reason?.isEmpty == false) ? reason : "permission prompt"
    }

    private static func status(for event: HookEvent) -> SessionStatus? {
        switch event.payload.event {
        case "SessionStart": return .idle
        case "UserPromptSubmit": return .busy
        case "PreToolUse", "PostToolUse": return .busy

        case "Notification":
            // **`Notification` means two entirely different things**, and treating them as one makes
            // the bar shout at you for pausing to read. From Claude Code's own strings:
            //
            //     "Claude needs your permission…"                 blocked on you        -> AMBER
            //     "Claude needs your approval for a review…"      blocked on you        -> AMBER
            //     "Claude needs your input"                       blocked on you        -> AMBER
            //     "Claude is waiting for your input"              the prompt has merely
            //                                                     been idle 60 seconds  -> NOTHING
            //
            // That last one fires when the *user* stops typing. It is not a request; it is Claude
            // noticing you went quiet. Mapping it to `.waiting` turned a session amber — "needs you" —
            // for the crime of being read rather than typed at. Observed doing exactly that, then
            // flicking back the moment a key was pressed.
            //
            // "needs your" is the discriminator: every genuine block says it, and the idle timeout
            // does not. An unrecognised message returns nil — no status change — because inventing an
            // interruption is strictly worse than missing one.
            guard let message = event.payload.message else { return nil }
            return message.localizedCaseInsensitiveContains("needs your") ? .waiting : nil

        case "Stop": return .idle
        // `SubagentStop` and anything Claude Code adds later: not modelled, and deliberately not a
        // status change. Unknown must be inert, never a guess.
        default: return nil
        }
    }

    private func isInteractive(_ pid: pid_t) -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastProbe) >= Self.probeInterval {
            lastProbe = now
            probedPIDs = ProcessProbe.liveClaudePIDs()
        }
        guard !probedPIDs.isEmpty else { return true } // probe is broken; fail open
        return probedPIDs.contains(pid)
    }

    // MARK: - Publish

    private func publish(_ changes: [SessionChange]) {
        // Tie-broken on `sessionId`, not pid: pids are optional now, Optionals aren't Comparable, and a
        // dormant agent has none to compare. The id is always present and stable, which is all a
        // deterministic tie-break needs.
        let sorted = snapshot.values.sorted {
            $0.startedAt == $1.startedAt
                ? $0.sessionId < $1.sessionId
                : $0.startedAt < $1.startedAt
        }
        let health = pipeIsConnected()

        lock.lock()
        published = sorted
        healthy = health
        lock.unlock()

        guard !changes.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onChange?(changes)
        }
    }

    private func refreshHealth() {
        let health = pipeIsConnected()
        lock.lock()
        healthy = health
        lock.unlock()
    }

    private func pipeIsConnected() -> Bool {
        FileManager.default.fileExists(atPath: eventsDirectory.path) && HookInstaller.isInstalled
    }
}

// MARK: - Wire format

/// One file dropped by `hook.sh`: the hook's stdin payload, plus the pid we had to supply ourselves.
private struct HookEvent: Decodable {
    /// `$PPID` of the hook — the `claude` process. The payload does not carry this, and teleport
    /// cannot work without it.
    let pid: pid_t
    /// Seconds since epoch, stamped by the hook.
    let at: Double?
    let payload: Payload

    var timestamp: Date? {
        guard let at, at > 0 else { return nil }
        return Date(timeIntervalSince1970: at)
    }

    struct Payload: Decodable {
        let sessionId: String?
        let cwd: String?
        let event: String?
        let reason: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case cwd
            case event = "hook_event_name"
            case reason
            case message
        }
    }
}
