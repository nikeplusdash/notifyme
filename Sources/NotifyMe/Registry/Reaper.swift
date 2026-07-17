import Foundation

/// Drops sessions whose process is gone.
///
/// Neither source can be trusted to tell us a session ended. The registry does **not** reliably remove
/// `~/.claude/sessions/<pid>.json` when the process is `SIGKILL`ed, and a killed session never gets to
/// fire its `SessionEnd` hook. Either way the record just sits there, cheerfully claiming to be `busy`
/// forever. So liveness is *probed*, not trusted.
///
/// A dead session is simply **removed** — the same as one that exited cleanly. It used to linger as a
/// red `.crashed` circle for twenty seconds first, on the theory that a death is worth seeing. But that
/// state only ever appears when a process is killed abnormally, which almost never happens, and the
/// rarity was buying a colour, a checkbox, a duration setting and a notification rule. From outside, a
/// session that died and a session that exited look the same: gone.
///
/// The reaper owns no queue and no timer. It is a pure fold over a snapshot, driven by whichever source
/// embeds it, on that source's own serial queue — so it inherits no threading model of its own.
public final class Reaper {

    /// How often a source should call `reap`.
    public static let interval: TimeInterval = 5

    public init() {}

    /// Remove every session whose process is gone, and report them.
    ///
    /// - `isAlive` is injectable so this can be driven deterministically in a harness rather than
    ///   waiting around for something to actually die.
    @discardableResult
    public func reap(
        snapshot: inout [pid_t: Session],
        isAlive: (Session) -> Bool = { $0.isAlive }
    ) -> [SessionChange] {
        var changes: [SessionChange] = []

        // Dictionary is a value type, so this iterates a copy — mutating `snapshot` inside the loop is
        // safe.
        // Still keyed by pid, and correctly so: this only ever reaps sessions that *have* a process.
        // A dormant background agent has no pid, never appears in a hook snapshot, and reports
        // `isAlive == true` precisely so that nothing here can delete it — a session blocked on the
        // user is not a corpse, and reaping it would erase the one thing worth showing.
        for (pid, session) in snapshot where !isAlive(session) {
            snapshot.removeValue(forKey: pid)
            changes.append(.disappeared(sessionId: session.sessionId, last: session))
        }

        return changes
    }

    /// Kept so sources can call it unconditionally when they drop a pid by other means. The reaper
    /// holds no per-pid state any more, so there is nothing to forget — but a source that had to *know*
    /// that would be a source coupled to the reaper's internals.
    public func forget(_ pid: pid_t) {}

    public func reset() {}
}
