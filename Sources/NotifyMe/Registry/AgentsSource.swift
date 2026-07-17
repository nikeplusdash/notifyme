import Foundation

/// `claude agents --json` — Claude Code's **own** view of its sessions.
///
/// This is the app's source of **identity**, and the only thing that can see a session with no process.
///
/// ## The hole it was written to close
///
/// The registry is a directory of files named after **live process ids**. A background agent that
/// finishes its turn and sits waiting for your reply **exits its process**. It keeps its conversation,
/// its name, and a `blocked` state — and it loses its pid, so its file goes away.
///
/// The result, measured on the machine this was built on:
///
///     Add SEO and open graph image support   background  blocked   no pid   INVISIBLE
///     backlog prioritization review          background  blocked   no pid   INVISIBLE
///     widget data provider expansion         background  blocked   no pid   INVISIBLE
///
/// Three sessions, blocked on the user for **days**, while the menu bar displayed the sessions that
/// were happily *working* and wanted nothing from anybody. The app was structurally incapable of
/// showing the only thing it exists to show.
///
/// ## It owns identity — and must never own status
///
/// The `status` it reports for a live session is the same bridge-written field the old registry carried,
/// and it **freezes silently** when that bridge drops. Measured here: `claude-session-tracker` reported
/// `idle` with a status **fourteen hours** stale, mid-work. So this source is not allowed anywhere near
/// the status of a session that has a pid — hooks own that, and `FusedSource` enforces it.
///
/// For a **pid-less** session there is no such conflict, and no alternative: no process, and no hook that
/// will ever fire again. Here its `state` is the only evidence that exists.
///
/// ## Cost
///
/// ~260 ms per call, spawning a process, so it is polled slowly and deliberately. Nothing is racing it: a
/// dormant agent cannot change state until a **human replies to it**, and a live session's status arrives
/// through hooks in milliseconds without waiting on this at all.
public final class AgentsSource: SessionSource {

    /// **Slow, and deliberately so.**
    ///
    /// Each poll spawns a process and costs **0.27 s of CPU** — measured. At the fifteen seconds this
    /// used to run at, that is 1.8% of a core burning permanently and 5,760 process launches a day, to
    /// re-read a list whose only unique contents — dormant agents — *cannot change unless a human
    /// replies to one*. There was nothing to race, and it was costing twelve times more than the entire
    /// rest of the app.
    ///
    /// The one thing that genuinely is urgent — a brand-new session's `name`, which is what the
    /// notification says — does not need polling at all: a hook announces the session in milliseconds,
    /// and `refresh()` then asks for its identity immediately. Waiting is now the exception, not the rule.
    private static let interval: DispatchTimeInterval = .seconds(120)

    /// Floor between polls, so a burst of new sessions cannot become a burst of process spawns.
    private static let minimumGap: TimeInterval = 10

    private let queue = DispatchQueue(label: "com.madebynikesh.NotifyMe.agents")
    private var snapshot: [String: Session] = [:]
    private var timer: DispatchSourceTimer?
    private var healthy = false
    private var lastPollStarted = Date.distantPast

    public var onChange: (([SessionChange]) -> Void)?

    public init() {}

    public var sessions: [Session] {
        queue.sync { snapshot.values.sorted { $0.startedAt < $1.startedAt } }
    }

    /// False until the CLI has answered once. A missing or broken `claude` binary must not be silent —
    /// it means the blocked agents are invisible again, which is the bug this class was written for.
    public var isHealthy: Bool { queue.sync { healthy } }

    public func start() {
        // Not on `queue`: `poll()` synchronises onto it, and a timer firing on the same serial queue
        // would `dispatch_sync` to the queue it is already running on — an instant deadlock. That
        // exact mistake took this app down once already, in `FusedSource`.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Polling

    /// Poll **now**, unless we just did.
    ///
    /// Called when a hook has announced a session this source has never heard of — a session that has
    /// just started, whose `name` only this source can supply. That name is what the notification says,
    /// and a session can easily finish inside one poll interval, so waiting two minutes to learn it is
    /// not an option.
    ///
    /// Debounced, because ten sessions starting at once must not become ten process launches.
    func refresh() {
        let now = Date()
        let go: Bool = queue.sync {
            guard now.timeIntervalSince(lastPollStarted) >= Self.minimumGap else { return false }
            lastPollStarted = now
            return true
        }
        guard go else { return }
        // Off this queue: `poll()` synchronises onto it.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.poll() }
    }

    private func poll() {
        queue.sync { lastPollStarted = Date() }

        // Logged because this is, by a wide margin, the most expensive thing the app does: a process
        // launch costing ~0.27s of CPU. If it ever starts happening often, that is a bug — and it would
        // otherwise be completely invisible, since nothing about it is user-facing.
        let started = Date()
        defer {
            Diagnostics.log("agents poll (\(Int(Date().timeIntervalSince(started) * 1000))ms)")
        }

        guard let rows = run() else {
            queue.sync { healthy = false }
            return
        }

        var changes: [SessionChange] = []
        queue.sync {
            healthy = true
            var next: [String: Session] = [:]
            for row in rows {
                guard let session = row.session() else { continue }
                next[session.sessionId] = session
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
            snapshot = next
        }

        guard !changes.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.onChange?(changes) }
    }

    /// Where the `claude` binary actually is.
    ///
    /// **Not** `/usr/bin/env claude`, and this is the whole point. A GUI app launched by LaunchServices
    /// does not inherit your shell's `PATH` — it gets launchd's, which is essentially
    /// `/usr/bin:/bin:/usr/sbin:/sbin`. `claude` installs to `~/.local/bin`, which is on none of them.
    ///
    /// So `env` returned **127, command not found**, on every single poll, and this source silently did
    /// nothing at all. The bug was invisible from a terminal — where every harness runs, with a full
    /// PATH, finding `claude` instantly and proving a thing that was not true of the shipped app.
    ///
    /// Resolved once and cached: this is asked every fifteen seconds, and the answer does not move.
    private static let executable: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/bin/claude"),
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        Diagnostics.log("cannot find the `claude` binary — dormant background agents will be invisible")
        return nil
    }()

    private func run() -> [Row]? {
        guard let executable = Self.executable else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["agents", "--json"]

        // The binary is found by absolute path above, but `claude` itself shells out — and it would
        // inherit this app's launchd-minimal PATH, which is the same trap one level down.
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = ([
            "\(home)/.local/bin", "/usr/local/bin", "/opt/homebrew/bin",
            environment["PATH"] ?? "/usr/bin:/bin",
        ]).joined(separator: ":")
        process.environment = environment

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        // The CLI warns "no stdin data received in 3s" and waits when stdin is a live pipe. A GUI app
        // has no terminal to give it, and three seconds of stall every poll is not acceptable.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Diagnostics.log("`claude agents --json` failed to launch: \(error.localizedDescription)")
            return nil
        }

        // Read *before* waiting. A pipe holds 64 KB; a user with many sessions overflows it, and the
        // child then blocks forever on a write nobody is draining, hanging this thread for good.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            Diagnostics.log("`claude agents --json` exited \(process.terminationStatus)")
            return nil
        }
        return try? JSONDecoder().decode([Row].self, from: data)
    }

    // MARK: - Wire format

    private struct Row: Decodable {
        let sessionId: String
        let cwd: String
        let name: String?
        let kind: String?
        let pid: pid_t?
        /// Live sessions carry this. Same bridge-written field the registry has, same staleness.
        let status: String?
        /// Background sessions carry this — and it is the only place `blocked` is ever reported.
        let state: String?
        /// Milliseconds since epoch.
        let startedAt: Double?

        func session() -> Session? {
            guard let mapped = Row.status(state: state, status: status) else { return nil }
            let started = startedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()

            // The CLI reports no transition time. Stamping `now` would make an agent that has been
            // blocked since **last week** announce itself as "waiting · 0s" — which reads as *this just
            // happened* and is the precise opposite of the truth.
            //
            // The transcript's last write is the moment it stopped and asked you something, so that is
            // the moment it started waiting. Falls back to `startedAt`, which is at least an
            // upper-bounded guess, before it will ever fall back to lying with `now`.
            let changed = Transcript.lastWritten(sessionId: sessionId, cwd: cwd) ?? started

            return Session(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                status: mapped,
                name: name ?? "",
                isBackground: kind == "background" || kind == "bg",
                startedAt: started,
                statusChangedAt: changed
            )
        }

        /// `state` wins over `status`: a background agent reports both, and only `state` distinguishes
        /// **blocked** — which is the entire reason this source exists.
        private static func status(state: String?, status: String?) -> SessionStatus? {
            switch state {
            case "blocked":
                // Blocked means it asked you something and stopped. `.waiting` is the status that fires
                // a "needs you" notification, which is the only voice this app has left.
                return .waiting
            case "working": return .busy
            case "done":    return .idle
            default: break
            }
            switch status {
            case "busy", "shell", "compacting", "starting": return .busy
            case "waiting": return .waiting
            case "idle":    return .idle
            default:        return .unknown
            }
        }
    }
}
