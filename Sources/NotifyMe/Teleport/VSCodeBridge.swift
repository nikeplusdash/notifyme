import Foundation

/// A window that answered `POST /focus` with "yes, that terminal is mine".
public struct BridgeFocusResult: Sendable, Equatable {
    public let port: Int
    /// Which of the pids we offered actually matched — the shell pid, or an ancestor.
    public let matchedPID: pid_t?
    /// The extension also brought its OS window to the front. When false, we do it ourselves.
    public let windowRaised: Bool
}

/// Talks to the NotifyMe companion extension.
///
/// **Why broadcast.** Every VS Code window runs its own extension host and its own loopback server,
/// and nothing outside VS Code can tell you which window owns a given terminal: the pty host
/// (`Code Helper`) is a *single* process shared by every window, so process ancestry converges on
/// the same two pids for every session. The only way to find the owner is to ask all of them and
/// let the one that recognises the shell pid claim it. Everyone else answers 404, which is normal,
/// not an error.
///
/// **Why this can't hang.** The extension may not be installed, may not have reloaded, or may have
/// left stale port files behind. Every path here is on a timeout, the whole fan-out is on a
/// watchdog, and `completion` fires exactly once regardless.
public final class VSCodeBridge {

    /// Where each VS Code window advertises its loopback port.
    public static let registryDirectory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".notifyme/ide")

    /// A window busy on the main thread still answers within a second or two. Past that we would
    /// rather degrade to window-level focus than make the user wait.
    private let requestTimeout: TimeInterval = 2.0
    private let overallTimeout: TimeInterval = 3.5

    private let session: URLSession
    private let queue = DispatchQueue(label: "com.madebynikesh.NotifyMe.bridge")

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = overallTimeout
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 8
        // This is loopback IPC. Anything cached, cookied or proxied is a bug.
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: config)
    }

    /// Ask every registered window to focus the terminal owning this session.
    ///
    /// `completion` gets the winning window, or nil if no window claimed the session (or there are
    /// no windows to ask). Called on an arbitrary queue, exactly once.
    public func focus(
        shellPID: pid_t?,
        ancestorPIDs: [pid_t],
        preferredWorkspace: String?,
        completion: @escaping (BridgeFocusResult?) -> Void
    ) {
        let registrations = Self.registrations(preferring: preferredWorkspace)
        guard !registrations.isEmpty else {
            completion(nil)
            return
        }

        var body: [String: Any] = [:]
        if let shellPID { body["shellPid"] = Int(shellPID) }
        if !ancestorPIDs.isEmpty { body["ancestorPids"] = ancestorPIDs.map(Int.init) }
        guard !body.isEmpty, let payload = try? JSONSerialization.data(withJSONObject: body) else {
            completion(nil)
            return
        }

        // Fire at every window at once. A serial sweep would cost `n × timeout` in the worst case,
        // and the worst case -- a pile of stale ports -- is exactly when the user is watching.
        let state = FanOut(pending: registrations.count, completion: completion)

        let watchdog = DispatchWorkItem { state.finish(nil) }
        // Armed before the first request goes out: a sweep that finishes instantly must still be
        // able to cancel it, or we leak a timer per teleport.
        state.onExhausted = { watchdog.cancel() }
        queue.asyncAfter(deadline: .now() + overallTimeout, execute: watchdog)

        for registration in registrations {
            post(payload, to: registration.port) { outcome in
                switch outcome {
                case .claimed(let result):
                    watchdog.cancel()
                    state.finish(result)
                case .declined:
                    state.oneDown()
                case .unreachable:
                    // Connection refused: that window is gone and took its port with it. The file
                    // is litter -- drop it so we stop dialling a dead number every teleport.
                    //
                    // Static on purpose. `completion` fires as soon as the *first* window claims the
                    // session, so these stragglers land afterwards -- and if cleanup went through
                    // `self`, it would silently stop happening whenever the caller let the bridge go.
                    Self.discard(port: registration.port)
                    state.oneDown()
                }
            }
        }
    }

    // MARK: - One window

    private enum Outcome {
        case claimed(BridgeFocusResult)
        case declined
        case unreachable
    }

    private func post(_ payload: Data, to port: Int, completion: @escaping (Outcome) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/focus") else {
            completion(.unreachable)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Deliberately no Origin header: the bridge 403s anything that carries one, as a guard
        // against a web page drive-by POSTing /focus at the user's editor.

        session.dataTask(with: request) { data, response, error in
            if let error = error as? URLError {
                switch error.code {
                case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
                    completion(.unreachable)
                default:
                    // Timed out, or something stranger. The window may simply be busy -- assume it
                    // still exists and leave its registration alone.
                    completion(.declined)
                }
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                let decoded = try? JSONDecoder().decode(FocusResponse.self, from: data),
                decoded.focused
            else {
                // 404 is the expected answer from every window that doesn't own this session.
                completion(.declined)
                return
            }
            completion(
                .claimed(
                    BridgeFocusResult(
                        port: port,
                        matchedPID: decoded.matchedPid.map(pid_t.init),
                        windowRaised: decoded.windowRaised ?? false
                    )
                )
            )
        }.resume()
    }

    private struct FocusResponse: Decodable {
        let focused: Bool
        let matchedPid: Int?
        /// Absent on older extension builds. Absent means "assume not" — a redundant activate() is
        /// harmless, a window that never comes forward is not.
        let windowRaised: Bool?
    }

    // MARK: - Which terminal is the user actually looking at?

    private struct HealthResponse: Decodable {
        /// Is *this window* the one the user is in? Absent on older extension builds.
        let focused: Bool?
        /// Shell pid of that window's active terminal. Absent on older builds; null if none.
        let activeTerminalShellPid: Int?
    }

    /// The shell pid of the terminal the user is looking at right now, across every VS Code window.
    ///
    /// This exists because the question **cannot be answered from outside VS Code**. Every window
    /// shares one OS process, so `NSWorkspace.frontmostApplication` reports "Visual Studio Code" and
    /// stops there — it cannot say which project, let alone which terminal tab. The notifier was
    /// suppressing on exactly that, which meant that whenever VS Code was frontmost (i.e. all day,
    /// while working) *every* notification for *every* session was silently swallowed, including the
    /// one this app exists to deliver.
    ///
    /// Only the focused window itself knows, so we ask each one and take the answer from whichever
    /// says it has focus.
    ///
    /// Returns `nil` when nothing can be established — no bridge, no focused window, an older
    /// extension. **`nil` must be read as "don't suppress."** A spurious notification is a nuisance;
    /// a swallowed one is a broken feature.
    /// A separate, **fast** session for the focus probe.
    ///
    /// The focus check sits directly in the notification path, so its timeout is a hard floor on how
    /// late a notification can be. The teleport session's 2s budget is right for a user-initiated
    /// click and completely wrong here: it would make every "session finished" up to two seconds late
    /// whenever a window's port had gone stale. Localhost either answers in microseconds or refuses
    /// the connection instantly; the only case this deadline is protecting against is a wedged
    /// extension host, and against that, giving up is the correct answer.
    private lazy var fastSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.3
        config.timeoutIntervalForResource = 0.4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    public func focusedTerminalShellPID(completion: @escaping (pid_t?) -> Void) {
        let registrations = Self.registrations(preferring: nil)
        guard !registrations.isEmpty else {
            completion(nil)
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var focusedPID: pid_t?

        for registration in registrations {
            guard let url = URL(string: "http://127.0.0.1:\(registration.port)/health") else { continue }
            group.enter()
            fastSession.dataTask(with: url) { data, _, _ in
                defer { group.leave() }
                guard
                    let data,
                    let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
                    health.focused == true,
                    let pid = health.activeTerminalShellPid
                else { return }
                lock.lock()
                focusedPID = pid_t(pid)
                lock.unlock()
            }.resume()
        }

        group.notify(queue: queue) {
            lock.lock()
            let pid = focusedPID
            lock.unlock()
            completion(pid)
        }
    }

    // MARK: - Registrations

    struct Registration: Equatable {
        let port: Int
        let workspace: String?

        // NB: the file also carries a `pid`, which we deliberately ignore. It is ambiguous — our
        // extension writes the per-window extension-host pid, Anthropic's writes the shared
        // main-process pid — so it can identify neither a window nor a stale entry. Whether the
        // port answers is the only staleness signal we trust.
    }

    /// Every advertised window, the one whose workspace matches this session first.
    ///
    /// The ordering is a latency optimisation only. Correctness comes from the broadcast: a session
    /// can perfectly well run in a terminal whose window has some *other* folder open.
    static func registrations(preferring workspace: String?) -> [Registration] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: registryDirectory,
                includingPropertiesForKeys: nil
            )) ?? []

        let found: [Registration] = files.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url) else {
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let port = json["port"] as? Int, port > 0, port < 65536
            else {
                // Unparseable, or half-written by a window booting right now. Not ours to clean up.
                return nil
            }
            return Registration(port: port, workspace: json["workspace"] as? String)
        }

        guard let workspace, !workspace.isEmpty else { return found }
        let normalised = (workspace as NSString).standardizingPath
        return found.sorted { a, b in
            let am = a.workspace.map { ($0 as NSString).standardizingPath == normalised } ?? false
            let bm = b.workspace.map { ($0 as NSString).standardizingPath == normalised } ?? false
            return am && !bm
        }
    }

    private static func discard(port: Int) {
        let file = registryDirectory.appendingPathComponent("\(port).json")
        try? FileManager.default.removeItem(at: file)
        Diagnostics.log("dropped stale registration for :\(port) (connection refused)")
    }
}

/// Collapses n concurrent answers into one `completion`, fired once.
private final class FanOut {
    private let lock = NSLock()
    private var pending: Int
    private var completion: ((BridgeFocusResult?) -> Void)?
    var onExhausted: (() -> Void)?

    init(pending: Int, completion: @escaping (BridgeFocusResult?) -> Void) {
        self.pending = pending
        self.completion = completion
    }

    /// A window claimed the session, or the watchdog fired. First one through wins.
    func finish(_ result: BridgeFocusResult?) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(result)
    }

    func oneDown() {
        lock.lock()
        pending -= 1
        let exhausted = pending <= 0
        lock.unlock()
        if exhausted {
            onExhausted?()
            finish(nil)
        }
    }
}
