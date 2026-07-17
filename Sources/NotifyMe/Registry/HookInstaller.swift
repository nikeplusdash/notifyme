import Foundation

/// Where the hook plumbing lives on disk.
///
/// Injectable rather than hardcoded for one reason: `install()` rewrites the user's real
/// `settings.json`, and that is not something to find out you got wrong in production. A `HookLayout`
/// pointing at a temp directory lets the whole install/uninstall round-trip be exercised against a
/// *copy* of their config.
public struct HookLayout {

    /// `~/.notifyme` — ours, not Claude Code's. Deleting it is always safe.
    public let root: URL

    /// The user's Claude Code config — **not ours**. We only ever merge into it.
    public let settings: URL

    /// The hook drops one JSON file per event here; `HookSource` consumes and deletes them.
    public var events: URL { root.appendingPathComponent("events", isDirectory: true) }

    /// The script Claude Code actually executes.
    public var script: URL { root.appendingPathComponent("hook.sh") }

    public init(root: URL, settings: URL) {
        self.root = root
        self.settings = settings
    }

    public static var `default`: HookLayout {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return HookLayout(
            root: home.appendingPathComponent(".notifyme", isDirectory: true),
            settings: home
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
        )
    }
}

/// Convenience for the default locations.
public enum HookPaths {
    public static var events: URL { HookLayout.default.events }
    public static var script: URL { HookLayout.default.script }
    public static var settings: URL { HookLayout.default.settings }
}

/// Installs (and removes) the NotifyMe hooks in the user's `~/.claude/settings.json`.
///
/// ## This mutates the user's configuration
///
/// `settings.json` is the user's file. It already holds their `model`, `enabledPlugins`,
/// `effortLevel` and whatever else, and they may well have their own hooks in it. So this merges,
/// never clobbers: unknown keys are round-tripped untouched, other people's hooks are left alone,
/// and `uninstall()` removes **only** entries pointing at our script.
///
/// Because of that, installation is **opt-in and never automatic**. Nothing in this app calls
/// `install()`; it exists to be wired to a switch in Settings that the user throws themselves.
public enum HookInstaller {

    /// Events we register for, and why:
    ///
    /// - `SessionStart` — a session exists; `.idle`.
    /// - `UserPromptSubmit` — the user asked for something; `.busy`.
    /// - `Notification` — Claude is blocked on the user; `.waiting`. This is the permission prompt.
    /// - `PreToolUse` / `PostToolUse` — a tool is running; `.busy`.
    /// - `Stop` — the turn finished; `.idle`. The headline event.
    /// - `SessionEnd` — gone.
    ///
    /// `PostToolUse` earns its keep despite firing on every single tool call: `PreToolUse` runs
    /// *before* the permission check, so the sequence around a prompt is
    /// `PreToolUse(busy) → Notification(waiting) → «user approves» → PostToolUse(busy)`. Without
    /// `PostToolUse` the session would sit there claiming to be `.waiting` long after the user
    /// unblocked it — which is precisely the state this app exists to report.
    static let events = [
        "SessionStart", "UserPromptSubmit", "Notification",
        "PreToolUse", "PostToolUse", "Stop", "SessionEnd",
    ]

    /// The events that take a tool-name matcher. The rest are matched unconditionally.
    private static let matcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    /// Hooks **block Claude Code**, so this stays POSIX `sh` and does no real work: no python, no
    /// node, no `jq`. It reads the payload, staples the pid on, and writes one file.
    ///
    /// Three things here are load-bearing:
    ///
    /// - **`$PPID` is the `claude` process.** The payload does not carry a pid, and teleport needs
    ///   one to find the terminal that owns the session. The hook's parent is `claude` itself.
    /// - **`exit 0`, always.** A non-zero exit from a `PreToolUse` hook is not a no-op — exit code 2
    ///   *blocks the tool call*. A tracker that can veto the user's tool calls because its disk
    ///   filled up would be an outrage. Failure here must be silent and harmless.
    /// - **Write to a temp name, then `mv`.** `rename(2)` within a directory is atomic, so the
    ///   watcher can never observe a half-written event.
    static func script(for layout: HookLayout) -> String {
        """
        #!/bin/sh
        # NotifyMe session hook. Installed by the NotifyMe menu bar app.
        # Safe to delete: without it, the app simply stops seeing sessions.
        #
        # Hooks block Claude Code, so this must stay fast and dependency-free.

        d="\(layout.events.path)"
        mkdir -p "$d" 2>/dev/null

        payload=$(cat)
        now=$(date +%s)

        # $$ is unique per invocation, so seconds resolution is enough to avoid collisions.
        f="$d/$now-$$"

        # Rename into place so the watcher never sees a partial event.
        printf '{"pid":%s,"at":%s,"payload":%s}' "$PPID" "$now" "$payload" > "$f.tmp" 2>/dev/null \\
          && mv "$f.tmp" "$f.json" 2>/dev/null

        # Never fail the hook: a non-zero exit from PreToolUse blocks the user's tool call.
        exit 0
        """
    }

    // MARK: - Query

    public static func isInstalled(_ layout: HookLayout = .default) -> Bool {
        guard
            FileManager.default.isExecutableFile(atPath: layout.script.path),
            let settings = readSettings(layout),
            let hooks = settings["hooks"] as? [String: Any]
        else { return false }

        return events.contains { event in
            groups(in: hooks, for: event).contains { containsOurHook($0, layout) }
        }
    }

    /// Default-layout convenience, for `HookSource`'s health check.
    public static var isInstalled: Bool { isInstalled(.default) }

    // MARK: - Install

    /// Merge our hooks into the user's `settings.json`.
    ///
    /// **Nothing in this app calls this.** It is wired to a switch the user throws themselves.
    ///
    /// Idempotent — installing twice does not double up. Backs the original file up first and writes
    /// atomically, so an interrupted install cannot leave the user without a config.
    public static func install(_ layout: HookLayout = .default) throws {
        let fm = FileManager.default

        try fm.createDirectory(at: layout.events, withIntermediateDirectories: true)
        try script(for: layout).write(to: layout.script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.script.path)

        var settings = readSettings(layout) ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in events {
            var eventGroups = groups(in: hooks, for: event)

            // Already ours — don't add a second copy.
            guard !eventGroups.contains(where: { containsOurHook($0, layout) }) else { continue }

            var group: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": layout.script.path,
                    // A wedged hook must not wedge Claude Code along with it.
                    "timeout": 5,
                ]]
            ]
            if matcherEvents.contains(event) { group["matcher"] = "*" }

            // Appended, never assigned: any hooks the user already had for this event keep their
            // place and run alongside ours.
            eventGroups.append(group)
            hooks[event] = eventGroups
        }

        settings["hooks"] = hooks
        try writeSettings(settings, layout)
    }

    // MARK: - Uninstall

    /// Remove **only** our entries, leaving hooks the user set up themselves untouched.
    public static func uninstall(_ layout: HookLayout = .default) throws {
        // Delete our own artefacts, and nothing else.
        //
        // `root` (~/.notifyme) is **shared**: Teleport keeps its VS Code bridge state in the
        // same directory. Removing the root wholesale would take another component's files with it,
        // so we remove what we put there and only reclaim the directory if that leaves it empty.
        defer {
            let fm = FileManager.default
            try? fm.removeItem(at: layout.events)
            try? fm.removeItem(at: layout.script)
            let remaining = (try? fm.contentsOfDirectory(atPath: layout.root.path)) ?? []
            if remaining.isEmpty { try? fm.removeItem(at: layout.root) }
        }

        guard var settings = readSettings(layout),
              var hooks = settings["hooks"] as? [String: Any]
        else { return }

        for event in events {
            var eventGroups = groups(in: hooks, for: event)
            guard !eventGroups.isEmpty else { continue }

            eventGroups = eventGroups.compactMap { group -> [String: Any]? in
                guard var commands = group["hooks"] as? [[String: Any]] else { return group }
                commands.removeAll { isOurs($0, layout) }
                // A group we emptied was ours alone, so drop it. A group that still holds the user's
                // own commands survives, minus ours.
                guard !commands.isEmpty else { return nil }
                var kept = group
                kept["hooks"] = commands
                return kept
            }

            if eventGroups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = eventGroups
            }
        }

        // Don't leave an empty `"hooks": {}` behind in a config that never had one.
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings, layout)
    }

    // MARK: - settings.json plumbing

    private static func groups(in hooks: [String: Any], for event: String) -> [[String: Any]] {
        hooks[event] as? [[String: Any]] ?? []
    }

    private static func isOurs(_ command: [String: Any], _ layout: HookLayout) -> Bool {
        (command["command"] as? String) == layout.script.path
    }

    private static func containsOurHook(_ group: [String: Any], _ layout: HookLayout) -> Bool {
        guard let commands = group["hooks"] as? [[String: Any]] else { return false }
        return commands.contains { isOurs($0, layout) }
    }

    private static func readSettings(_ layout: HookLayout) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: layout.settings),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Write `settings.json` back atomically, keeping a backup of what was there before.
    ///
    /// Note: JSON objects are unordered, so the user's keys may come back in a different order than
    /// they went in. Every key and value is preserved — this is a re-serialisation, not a rewrite —
    /// but the diff will look bigger than it is.
    private static func writeSettings(_ settings: [String: Any], _ layout: HookLayout) throws {
        let url = layout.settings

        if let original = try? Data(contentsOf: url) {
            let backup = url.appendingPathExtension("notifyme-backup")
            try? original.write(to: backup, options: .atomic)
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}
