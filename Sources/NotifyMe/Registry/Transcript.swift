import Foundation

/// Claude Code's own record of a conversation:
/// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` — append-only, written live, one JSON object
/// per line.
///
/// This exists to answer one question: **what did it actually say?**
///
/// A notification reading *"acme-app finished — ~/Projects/acme-app"* tells you
/// nothing you did not already know. It cannot be acted on, so it forces you to go and look — and that
/// is the real reason teleport gets used at all. You are not jumping to VS Code because you want to be
/// in VS Code; you are jumping because the notification refused to tell you what happened.
///
/// Putting Claude's closing message in the body removes most of the *need* to jump. The transcript is
/// already on disk and we already hold the `sessionId` and `cwd` for every session, so this costs a
/// file read and nothing else — no daemon, no bridge, no extension, nothing that can go stale.
public enum Transcript {

    /// The last thing Claude actually *said* in this session, flattened to one line of prose and
    /// trimmed to fit a notification body. Nil if there is no transcript, or nothing said yet.
    public static func lastAssistantText(sessionId: String, cwd: String, limit: Int = 220) -> String? {
        guard let url = url(sessionId: sessionId, cwd: cwd),
              let raw = lastAssistantText(in: url)
        else { return nil }
        return condense(raw, to: limit)
    }

    /// When this session last **wrote** anything — i.e. when it last spoke.
    ///
    /// For a dormant background agent this is the honest answer to "how long has it been waiting?".
    /// Nothing else can tell us: the CLI reports no transition time, so a freshly-seen agent would
    /// otherwise be stamped `now` and a session blocked for **nine days** would read "waiting · 0s" —
    /// which reads as *something just happened*, the exact opposite of the truth, and would send you
    /// running to a session that has been quietly parked since last week.
    ///
    /// The last line of the transcript was written the moment it stopped and asked you something. That
    /// file's mtime is that moment.
    public static func lastWritten(sessionId: String, cwd: String) -> Date? {
        guard let url = url(sessionId: sessionId, cwd: cwd),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        else { return nil }
        return values.contentModificationDate
    }

    // MARK: - Locating it

    private static func url(sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)

        // Claude Code encodes the cwd into a directory name by replacing every "/" with "-", so
        // `/Users/x/Projects` becomes `-Users-x-Projects`.
        let direct = projects
            .appendingPathComponent(cwd.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
        if fm.fileExists(atPath: direct.path) { return direct }

        // That encoding is undocumented, and a session whose cwd was a symlink (or a `/tmp` path that
        // resolves to `/private/tmp`) lands somewhere the rule above does not predict. The session id
        // is globally unique, so a scan finds the file wherever it actually went — and a notification
        // that quietly loses its body is worse than one extra directory listing.
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)
        else { return nil }
        return dirs
            .map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - Reading it

    /// How far back to look, growing until the message turns up.
    ///
    /// Transcripts run to tens of megabytes, so the file is never read whole. But a **fixed** tail is a
    /// coin flip, and that is the trap: a single JSONL line can be a quarter of a megabyte on its own —
    /// one large tool result — so whether the last message falls inside a 256 KB window depends entirely
    /// on what the session happened to be doing when it stopped.
    ///
    /// Measured, on a live 28 MB transcript: its final 256 KB contained **one** 255 KB line and six rows
    /// of metadata (`last-prompt`, `ai-title`, `agent-name`, `mode`…) — the file *ends* in bookkeeping,
    /// not in conversation. The notification silently fell back to printing the folder path, which is
    /// precisely the uninformative body this class exists to replace. It would have kept working most of
    /// the time and failed exactly on the turns that did the most work.
    ///
    /// Bounded, because a session that genuinely never spoke must not drag 28 MB through memory to prove
    /// it. Three reads at worst, and the first one almost always wins.
    private static let windows: [UInt64] = [256 * 1024, 1024 * 1024, 4 * 1024 * 1024]

    private static func lastAssistantText(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }

        for window in Self.windows {
            let start = end > window ? end - window : 0
            try? handle.seek(toOffset: start)
            guard let data = try? handle.readToEnd() else { return nil }

            if let text = scan(data, startsMidLine: start > 0) { return text }
            // Already read from byte zero — a larger window cannot show us anything new.
            if start == 0 { break }
        }
        return nil
    }

    private static func scan(_ data: Data, startsMidLine: Bool) -> String? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)

        // Seeking to a byte offset lands mid-line. That first fragment is not valid JSON, and letting it
        // fail to parse would look identical to "there is no message here".
        if startsMidLine, lines.count > 1 { lines.removeFirst() }

        for line in lines.reversed() {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  row["type"] as? String == "assistant",
                  let message = row["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]]
            else { continue }

            // A turn's content is a list: thinking, tool calls, and text, in the order they happened.
            // Walk it backwards — the closing remarks are what a person wants, not the reasoning that
            // led there.
            for block in blocks.reversed() where block["type"] as? String == "text" {
                let text = (block["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    // MARK: - Fitting it in a banner

    /// A notification body is two or three lines of **plain text**. Claude writes markdown, and a banner
    /// renders none of it — so every marker arrives as literal punctuation. Observed in a real
    /// notification, verbatim:
    ///
    ///     The window is **sometimes** too small — that's worse than always.
    ///
    /// Flattening whitespace was never enough; the markers have to go too.
    private static func condense(_ text: String, to limit: Int) -> String {
        // Line-level work first, while "the start of a line" still means something. Once the lines are
        // joined, that information is gone for good.
        var kept: [String] = []
        var insideFence = false

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code. It is source, not prose, and flattened it arrives as one unreadable run of
            // syntax that crowds out the sentence explaining it.
            if line.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }

            // A markdown **table** cannot survive being flattened — it becomes pipes and dashes. Seen in
            // a real notification, verbatim:
            //
            //     … was the broken pgrep. | | before | after | |---|---|---| | sustained CPU | 1.95% …
            //
            // Dropped whole rather than salvaged: the numbers are meaningless without their headers, and
            // the prose beside them is what a person can actually act on.
            if line.hasPrefix("|") { continue }

            // Headings, bullets, quotes.
            let stripped = line.replacingOccurrences(
                of: "^(#{1,6}|[-*+•]|>)\\s+", with: "", options: .regularExpression
            )
            if !stripped.isEmpty { kept.append(stripped) }
        }

        // A message that was *nothing but* a table or a code block leaves us holding nothing. Saying
        // something imperfect beats saying nothing at all, so fall back to the raw text.
        if kept.isEmpty {
            kept = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        var flat = kept.joined(separator: " ")

        // `[text](url)` → text. The URL is unclickable here and eats the character budget.
        flat = flat.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression
        )

        // Bold and code spans. **Not** lone `*` or `_`: stripping those would turn `snake_case` into
        // `snakecase` and quietly corrupt the identifiers that make a body worth reading. Backticks are
        // safe to drop for the same reason — an identifier is nearly always inside them, and removing
        // the fence leaves the name intact.
        for marker in ["**", "__", "`"] {
            flat = flat.replacingOccurrences(of: marker, with: "")
        }

        flat = flat.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }

        // Cut on a word boundary. A body ending "…the FusedSource now fires onCha" reads like a bug.
        let cut = flat.prefix(limit)
        if let space = cut.lastIndex(of: " ") {
            return cut[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut + "…"
    }

    /// Exposed so the markdown flattening can be exercised directly. It has already shipped one bug
    /// straight to a notification banner.
    static func condenseForTest(_ text: String, to limit: Int = 220) -> String {
        condense(text, to: limit)
    }
}
