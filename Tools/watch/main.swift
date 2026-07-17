import Foundation

// Verification harness for the data layer.
//
// There is no Xcode and no XCTest runner on this machine, so this is how the sources get proven:
// point them at the real registry, watch real sessions, and read the transitions as they happen.
//
//   swiftc -o /tmp/ctwatch Sources/NotifyMe/Model/*.swift \
//                          Sources/NotifyMe/Registry/*.swift \
//                          Tools/watch/main.swift -framework AppKit
//
//   /tmp/ctwatch                  # the real ~/.claude/sessions
//   /tmp/ctwatch --dir  <path>    # a fixture registry directory
//   /tmp/ctwatch --hooks <path>   # a fixture hook-events directory (HookSource)
//
// `Tools/` sits outside `Sources/`, so this main.swift never collides with the app's own, and
// `make build` (which globs `Sources`) doesn't pick it up.

// Line-buffer stdout: piped to a file it would otherwise block-buffer, and a harness whose output
// only appears once it exits is useless for watching a live system.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Formatting

let clock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

let dim = "\u{1B}[2m", bold = "\u{1B}[1m", reset = "\u{1B}[0m"

func colour(_ status: SessionStatus) -> String {
    switch status {
    case .busy: return "\u{1B}[34m"    // blue
    case .waiting: return "\u{1B}[33m" // amber
    case .idle: return "\u{1B}[32m"    // green
    case .unknown: return "\u{1B}[90m" // grey
    }
}

func stamp() -> String { "\(dim)\(clock.string(from: Date()))\(reset)" }

/// Pad to a fixed width. Done by hand because the columns carry ANSI colour, and `padding(toLength:)`
/// counts escape bytes as visible characters.
func pad(_ text: String, _ width: Int) -> String {
    text.count >= width
        ? text
        : text + String(repeating: " ", count: width - text.count)
}

func describe(_ s: Session) -> String {
    let status = "\(colour(s.status))\(s.status.rawValue)\(reset)"
    let waiting = s.waitingFor.map { " \(dim)(\($0))\(reset)" } ?? ""
    let who = s.pid.map { "pid \($0)" } ?? "no-proc"
    return "\(who) \(status)\(waiting) \(bold)\(s.displayName)\(reset) [\(s.directoryName)]"
}

func table(_ sessions: [Session], health: Bool, extra: [String] = []) {
    let badge = health ? "\u{1B}[32mhealthy\(reset)" : "\u{1B}[31mDEGRADED\(reset)"
    print("\n\(bold)── sessions (\(sessions.count)) ── \(badge)\(reset)")

    if sessions.isEmpty {
        print("  \(dim)(none)\(reset)")
    } else {
        // Ordered by startedAt — the same order the menu bar will draw them in.
        print("  \(dim)PID      STATUS    AGE    STARTED   NAME                            DIRECTORY\(reset)")
        for s in sessions {
            let age: Int = Int(Date().timeIntervalSince(s.statusChangedAt))
            let pid: String = pad(s.pid.map(String.init) ?? "—", 9)
            let status: String = pad(s.status.rawValue, 10)
            let ageText: String = pad("\(age)s", 7)
            let started: String = pad(String(clock.string(from: s.startedAt).prefix(8)), 10)
            let name: String = pad(s.displayName, 32)
            let dir: String = s.directoryName
            let tint: String = colour(s.status)
            print("  \(pid)\(tint)\(status)\(reset)\(ageText)\(started)\(bold)\(name)\(reset)\(dir)")
        }
    }
    for line in extra { print("  \(dim)\(line)\(reset)") }
    print("")
}

// MARK: - Wiring

var args = Array(CommandLine.arguments.dropFirst())
var source: SessionSource
var label: String

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - --test-installer
//
// Exercises the full install → re-install → uninstall round trip against a **copy** of the user's
// settings.json in a temp directory. The real ~/.claude/settings.json is never opened for writing:
// the whole point of HookLayout being injectable is that this test cannot touch it.

func check(_ ok: Bool, _ what: String) {
    let mark = ok ? "\u{1B}[32m✓\(reset)" : "\u{1B}[31m✗\(reset)"
    print("  \(mark) \(what)")
    if !ok { installerFailures += 1 }
}
var installerFailures = 0

if let dir = value(after: "--test-installer") {
    let root = URL(fileURLWithPath: dir)
    let fm = FileManager.default
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)

    let settingsURL = root.appendingPathComponent("settings.json")
    let layout = HookLayout(
        root: root.appendingPathComponent("tracker-home"),
        settings: settingsURL
    )

    // A copy of the user's real config, plus a hook they already had. Both must survive us.
    let real = HookLayout.default.settings
    var original = (try? JSONSerialization.jsonObject(with: Data(contentsOf: real))
        as? [String: Any]) ?? [:]
    original["hooks"] = [
        "Stop": [[
            "hooks": [["type": "command", "command": "/usr/local/bin/the-users-own-hook.sh"]]
        ]]
    ]
    let originalKeys = Set(original.keys)
    try! JSONSerialization
        .data(withJSONObject: original, options: [.prettyPrinted, .withoutEscapingSlashes])
        .write(to: settingsURL)

    print("\(bold)── HookInstaller round-trip\(reset)  \(settingsURL.path)\n")
    print("\(dim)before:\(reset)")
    print(try! String(contentsOf: settingsURL, encoding: .utf8))

    check(!HookInstaller.isInstalled(layout), "reports not-installed beforehand")

    try! HookInstaller.install(layout)
    try! HookInstaller.install(layout) // idempotency: a second install must not double up

    let afterData = try! Data(contentsOf: settingsURL)
    let after = try! JSONSerialization.jsonObject(with: afterData) as! [String: Any]
    let afterHooks = after["hooks"] as! [String: Any]

    print("\n\(dim)after install (×2):\(reset)")
    print(String(decoding: afterData, as: UTF8.self))

    check(HookInstaller.isInstalled(layout), "reports installed")
    check(
        originalKeys.isSubset(of: Set(after.keys)),
        "user's other keys preserved (\(originalKeys.sorted().joined(separator: ", ")))"
    )
    check(
        (after["model"] as? String) == (original["model"] as? String),
        "`model` value preserved verbatim"
    )
    check(
        Set(afterHooks.keys) == Set(HookInstaller.events),
        "registered exactly our events"
    )

    let stopGroups = afterHooks["Stop"] as! [[String: Any]]
    let stopCommands = stopGroups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        .compactMap { $0["command"] as? String }
    check(
        stopCommands.contains("/usr/local/bin/the-users-own-hook.sh"),
        "the user's own Stop hook survived install"
    )
    check(
        stopCommands.filter { $0 == layout.script.path }.count == 1,
        "our Stop hook appears exactly once after installing twice (idempotent)"
    )
    check(
        (afterHooks["PreToolUse"] as! [[String: Any]]).allSatisfy { $0["matcher"] != nil },
        "PreToolUse carries a matcher"
    )
    check(
        fm.isExecutableFile(atPath: layout.script.path),
        "hook.sh written and executable"
    )

    // ~/.notifyme is shared — Teleport keeps its VS Code bridge state in the same directory.
    // Uninstall must reclaim our files without taking someone else's with them.
    let foreign = layout.root.appendingPathComponent("vscode-bridge.port")
    try! "51234".write(to: foreign, atomically: true, encoding: .utf8)

    try! HookInstaller.uninstall(layout)

    check(fm.fileExists(atPath: foreign.path), "a foreign file in the shared root survived uninstall")
    check(!fm.fileExists(atPath: layout.script.path), "our hook.sh removed")
    check(!fm.fileExists(atPath: layout.events.path), "our events/ removed")
    try? fm.removeItem(at: foreign)

    let finalData = try! Data(contentsOf: settingsURL)
    let final = try! JSONSerialization.jsonObject(with: finalData) as! [String: Any]
    print("\n\(dim)after uninstall:\(reset)")
    print(String(decoding: finalData, as: UTF8.self))

    let finalHooks = final["hooks"] as? [String: Any] ?? [:]
    let finalStop = (finalHooks["Stop"] as? [[String: Any]] ?? [])
        .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        .compactMap { $0["command"] as? String }

    check(originalKeys.isSubset(of: Set(final.keys)), "user's other keys still there after uninstall")
    check(
        finalStop == ["/usr/local/bin/the-users-own-hook.sh"],
        "the user's own Stop hook is all that remains"
    )
    check(finalHooks["PreToolUse"] == nil, "our PreToolUse entry removed entirely")
    check(!HookInstaller.isInstalled(layout), "reports not-installed afterwards")

    print("")
    if installerFailures == 0 {
        print("\u{1B}[32m\(bold)all installer checks passed\(reset)")
    } else {
        print("\u{1B}[31m\(bold)\(installerFailures) installer check(s) FAILED\(reset)")
    }
    exit(installerFailures == 0 ? 0 : 1)
}

if let hooks = value(after: "--hooks") {
    let url = URL(fileURLWithPath: hooks)
    source = HookSource(eventsDirectory: url)
    label = "HookSource  \(url.path)"
} else {
    // What the app actually runs. This used to default to `RegistrySource` alone, which meant it
    // faithfully reproduced the app's biggest blind spot instead of exposing it — a harness that
    // exercises one source cannot catch a bug in the fusion of two.
    source = FusedSource()
    label = "FusedSource  (registry + hooks + claude agents)"
}

print("\(bold)ctwatch\(reset)  \(label)")
print("\(dim)watching… ^C to stop\(reset)")

func diagnostics() -> [String] {
    // What each source can and cannot see. The two failure modes that actually happened both looked
    // like "nothing to report" from the outside: hooks not installed, and `claude agents` failing with
    // 127 because a GUI app does not inherit the shell's PATH.
    var lines: [String] = []
    lines.append("hooks installed: \(HookInstaller.isInstalled ? "yes" : "NO — status will be wrong")")
    let dormant = source.sessions.filter { !$0.hasProcess }.count
    lines.append("dormant (no process, only `claude agents` can see them): \(dormant)")
    return lines
}

source.onChange = { changes in
    for change in changes {
        switch change {
        case .appeared(let s):
            print("\(stamp()) \u{1B}[32m+ APPEARED\(reset)     \(describe(s))")
        case .statusChanged(let s, let from):
            print(
                "\(stamp()) \u{1B}[36m~ STATUS\(reset)       \(s.displayName) "
                    + "\(colour(from))\(from.rawValue)\(reset) → \(colour(s.status))\(s.status.rawValue)\(reset)"
                    + "  \(bold)\(s.displayName)\(reset)"
                    + (s.waitingFor.map { " \(dim)(\($0))\(reset)" } ?? "")
            )
        case .disappeared(let pid, let last):
            print("\(stamp()) \u{1B}[31m- DISAPPEARED\(reset)  pid \(pid)  \(bold)\(last.displayName)\(reset)")
        }
    }
    table(source.sessions, health: source.isHealthy, extra: diagnostics())
}

source.start()
table(source.sessions, health: source.isHealthy, extra: diagnostics())

// Re-print the table periodically so status ages stay live even when nothing is transitioning.
if args.contains("--tick") {
    Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
        table(source.sessions, health: source.isHealthy, extra: diagnostics())
    }
}

RunLoop.main.run()
