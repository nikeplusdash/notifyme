/// Verification harness for Teleport + Notify.
///
/// There is no Xcode and therefore no XCTest here, and the things most worth testing — "does VS Code
/// actually come forward", "does a notification actually appear" — are not unit-testable anyway.
/// So this drives the real code against the real machine.
///
/// Lives outside `Sources/`, so it can't collide with the app's own `main.swift` or be swept into
/// `make build`.
///
///     swiftc -o /tmp/cttp \
///       Sources/NotifyMe/Model/*.swift \
///       Sources/NotifyMe/Teleport/*.swift \
///       Sources/NotifyMe/Notify/*.swift \
///       Tools/teleport/main.swift \
///       -framework AppKit -framework UserNotifications
///
/// Commands:
///     cttp resolve                 walk every live claude session up to its GUI host
///     cttp bridge [pid]            list registered VS Code windows, and try POST /focus
///     cttp teleport <pid>          the real thing. STEALS FOCUS.
///     cttp notify <pid> [kind]     fire a real notification (done | waiting | crash), then wait
///                                  ~40s so you can click it and watch the teleport happen.
///
/// `notify` only reaches UNUserNotificationCenter when run from inside a bundle; unbundled it
/// reports the osascript fallback instead. `Tools/teleport/bundle.sh` builds the bundle.

import AppKit
import Foundation
import UserNotifications

Diagnostics.verbose = true

// MARK: - Session discovery

/// The working directory of a live process. `lsof` rather than `proc_pidinfo`, which needs
/// entitlements we don't have.
func workingDirectory(of pid: pid_t) -> String? {
    let (status, output) = Shell.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"], timeout: 8)
    guard status == 0 else { return nil }
    for line in output.split(separator: "\n") where line.hasPrefix("n") {
        return String(line.dropFirst())
    }
    return nil
}

/// Every live `claude`, as a `Session` good enough to teleport to.
func liveSessions() -> [Session] {
    ProcessProbe.liveClaudePIDs().sorted().map { pid in
        let cwd = workingDirectory(of: pid) ?? ""
        return Session(
            pid: pid,
            sessionId: "harness-\(pid)",
            cwd: cwd,
            status: .busy,
            name: "",
            startedAt: Date(),
            statusChangedAt: Date()
        )
    }
}

func session(withPID pid: pid_t) -> Session? {
    liveSessions().first { $0.pid == pid }
}

func printHeader(_ title: String) {
    print("\n\u{1B}[1m\(title)\u{1B}[0m")
    print(String(repeating: "─", count: title.count))
}

// MARK: - Commands

let resolver = HostResolver()
let teleporter = Teleporter()

func cmdResolve() {
    let sessions = liveSessions()
    printHeader("HostResolver — \(sessions.count) live claude process(es)")
    guard !sessions.isEmpty else {
        print("none running.")
        return
    }
    for session in sessions {
        let r = resolver.resolve(session)
        let host = r.host
        print("")
        print("  claude pid   \(session.pid)")
        print("  cwd          \(session.cwd.isEmpty ? "—" : session.cwd)")
        print("  shell pid    \(r.shellPID.map(String.init) ?? "—")   ← what VS Code reports as Terminal.processId")
        print("  ancestry     \(r.ancestorPIDs.map(String.init).joined(separator: " → "))")
        print("  tty          \(r.tty ?? "—")")
        print("  host app     \(host?.name ?? "NONE") \(host.map { "(pid \($0.pid), \($0.bundleIdentifier ?? "?"))" } ?? "")")
        print("  host kind    \(host.map { "\($0.kind)" } ?? "—")")
        print("  cli          \(host?.cliPath ?? "—")")
    }
}

func cmdBridge(_ pid: pid_t?) {
    printHeader("VS Code bridge")
    let registrations = VSCodeBridge.registrations(preferring: nil)
    print("registry: \(VSCodeBridge.registryDirectory.path)")
    if registrations.isEmpty {
        print("no windows registered — the extension is not installed or not reloaded.")
        print("teleport will fall back to `code -r <cwd>` + app activation.")
    } else {
        for r in registrations {
            print("  port \(r.port)  workspace=\(r.workspace ?? "none")")
        }
    }

    guard let pid, let session = session(withPID: pid) else { return }
    let resolved = resolver.resolve(session)
    print("\nfull ancestry     \(resolved.ancestorPIDs)")
    print("POST /focus  shellPid=\(resolved.shellPID.map(String.init) ?? "nil") ancestorPids=\(resolved.bridgeCandidatePIDs)  ← shared pty host + app trimmed off")

    let bridge = VSCodeBridge()
    let done = DispatchSemaphore(value: 0)
    bridge.focus(
        shellPID: resolved.shellPID,
        ancestorPIDs: resolved.bridgeCandidatePIDs,
        preferredWorkspace: session.cwd
    ) { result in
        if let result {
            print("→ claimed by window on port \(result.port), matchedPid=\(result.matchedPID.map(String.init) ?? "?"), windowRaised=\(result.windowRaised)")
        } else {
            print("→ no window claimed it")
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 8)

    // `completion` fires on the FIRST claim; the losing windows answer afterwards, and that's when
    // stale ports get reaped. Give those stragglers a moment before we exit out from under them.
    Thread.sleep(forTimeInterval: 1.5)
}

func cmdTeleport(_ pid: pid_t) {
    guard let session = session(withPID: pid) else {
        print("no live claude with pid \(pid)")
        exit(1)
    }
    printHeader("Teleport → pid \(pid) (\(session.cwd))")
    print("this steals focus in 2s…")
    Thread.sleep(forTimeInterval: 2)
    teleporter.teleport(to: session)
    RunLoop.main.run(until: Date().addingTimeInterval(8))
    print("\ndone — did the right window come forward?")
}

func cmdNotify(_ pid: pid_t, kind: String) {
    let target =
        session(withPID: pid)
        ?? Session(
            pid: pid, sessionId: "harness", cwd: FileManager.default.currentDirectoryPath,
            status: .busy, name: "", startedAt: Date(), statusChangedAt: Date()
        )

    printHeader("Notify — \(kind)")
    print("bundle id       \(Bundle.main.bundleIdentifier ?? "NONE (unbundled)")")
    print("frontmost app   \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

    let notifier = Notifier(teleporter: teleporter)
    print("backend         \(notifier.backendName)")
    notifier.requestAuthorization()

    var session = target
    let from: SessionStatus
    switch kind {
    case "waiting":
        session.status = .waiting
        session.waitingFor = "permission prompt"
        from = .busy
    default:
        session.status = .idle
        from = .busy
    }
    session.statusChangedAt = Date()

    // Give the authorization prompt a beat to resolve before we post into it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        notifier.handle([.statusChanged(session: session, from: from)])
    }

    print("\nposting in 1.5s — click the banner to test teleport-on-click. waiting 40s…")
    RunLoop.main.run(until: Date().addingTimeInterval(40))
    print("done.")
}

/// Is `UNUserNotificationCenter` actually usable here, and if not, exactly how does it refuse?
///
/// The whole reason `Notifier` carries an osascript fallback. Answering this needs the authorization
/// *status*, not just whether `requestAuthorization` errored — the two disagree, and only the status
/// is authoritative.
func cmdNotifyDiag() {
    // Also to a file: a GUI app launched through LaunchServices has no usable stdout, and the whole
    // point of this command is to observe an app launched *the way the real one is*.
    func print(_ line: String) {
        Swift.print(line)
        let stamped = line + "\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/ctdiag.log") {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(toFile: "/tmp/ctdiag.log", atomically: true, encoding: .utf8)
        }
    }

    printHeader("UNUserNotificationCenter diagnosis")
    print("bundle id     \(Bundle.main.bundleIdentifier ?? "NONE — unbundled")")
    print("bundle path   \(Bundle.main.bundlePath)")

    guard Bundle.main.bundleIdentifier != nil else {
        print("\nunbundled: .current() would raise an Obj-C exception. Notifier uses osascript.")
        return
    }

    func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined (no prompt answered yet)"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    let center = UNUserNotificationCenter.current()
    let done = DispatchSemaphore(value: 0)

    center.getNotificationSettings { before in
        print("status BEFORE \(describe(before.authorizationStatus))")

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            print("requestAuth   granted=\(granted) error=\(error.map { "\($0.localizedDescription)" } ?? "none")")

            center.getNotificationSettings { after in
                print("status AFTER  \(describe(after.authorizationStatus))")

                let content = UNMutableNotificationContent()
                content.title = "NotifyMe diag"
                content.body = "UNUserNotificationCenter delivered this."
                center.add(
                    UNNotificationRequest(identifier: "diag-\(UUID())", content: content, trigger: nil)
                ) { addError in
                    print("add()         \(addError.map { "FAILED: \($0.localizedDescription)" } ?? "accepted")")
                    done.signal()
                }
            }
        }
    }

    _ = done.wait(timeout: .now() + 25)
    RunLoop.main.run(until: Date().addingTimeInterval(6))
}

// MARK: - Entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "resolve"
let argPID = args.count > 1 ? pid_t(args[1]) : nil

switch command {
case "resolve":
    cmdResolve()
case "bridge":
    cmdBridge(argPID)
case "teleport":
    guard let argPID else {
        print("usage: cttp teleport <pid>")
        exit(1)
    }
    cmdTeleport(argPID)
case "diag":
    cmdNotifyDiag()
case "notify":
    guard let argPID else {
        print("usage: cttp notify <pid> [done|waiting|crash]")
        exit(1)
    }
    cmdNotify(argPID, kind: args.count > 2 ? args[2] : "done")
default:
    print("usage: cttp [resolve | bridge [pid] | teleport <pid> | notify <pid> [done|waiting|crash]]")
    exit(1)
}
