import Foundation
import os

/// The app's log.
///
/// Lives at the top level, deliberately. It used to be declared inside `Teleport/Teleporter.swift`,
/// which was harmless only for as long as nothing below the UI layer wanted to log. The moment
/// `Registry` and `Model` needed it — a source reporting that `claude agents` failed, preferences
/// reporting a migration — that placement inverted the dependencies: the data layer could not be
/// compiled without the teleport layer, and the `Tools/watch` harness (which builds `Model` plus
/// `Registry` and nothing else, precisely so the data layer can be proven on its own) stopped
/// building at all.
///
/// Logging is cross-cutting. It belongs to no layer, so it sits above all of them.
public enum Diagnostics {

    /// Mirror everything to stderr. What the `Tools/*` harnesses switch on: the same code paths the
    /// app runs, but narrating themselves so a human can watch a teleport — or a merge — happen.
    ///
    /// Off in the app, where stderr goes nowhere. `os_log` always receives the message regardless, so
    /// a shipped build can still be watched live with:
    ///
    ///     log stream --predicate 'subsystem == "com.madebynikesh.NotifyMe"' --level debug
    ///
    /// (Note `/usr/bin/log`, spelled out — **zsh has its own `log` builtin** that silently shadows it
    /// and does nothing, which quietly wasted an afternoon.)
    public static var verbose = false

    /// The subsystem is the app's bundle id, `com.madebynikesh.NotifyMe`. It is a log channel, not an
    /// identity, and every debugging command written down anywhere — in these comments, in a scratch
    /// note — greps for this string.
    private static let logger = Logger(subsystem: "com.madebynikesh.NotifyMe", category: "teleport")

    public static func log(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        if verbose { FileHandle.standardError.write(Data(("  · " + message + "\n").utf8)) }
    }
}
