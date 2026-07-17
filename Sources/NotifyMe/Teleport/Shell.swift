import Foundation

/// Subprocess plumbing for teleport.
///
/// Every call here is on a watchdog. The menu bar must never be held hostage by a wedged
/// `osascript` waiting on an Automation permission prompt, or a `code` CLI that can't reach its
/// Electron host.
enum Shell {

    /// Run to completion and capture stdout. Returns `-1` on spawn failure or timeout.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> (
        status: Int32, output: String
    ) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return (-1, "") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return (-1, "") }

        // Drain on another thread: a child that outfills the 64K pipe buffer would otherwise block
        // forever on write() while we block forever on waitUntilExit(). `code --status` is ~4K
        // today, which is only comfortable until it isn't.
        let sink = Box(Data())
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            sink.value = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exited.signal()
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
        }
        _ = drained.wait(timeout: .now() + 2)

        let status = process.isRunning ? -1 : process.terminationStatus
        return (status, String(decoding: sink.value, as: UTF8.self))
    }

    /// Spawn and walk away. For `code -r`, which raises a window as a side effect and whose exit we
    /// have no use for.
    static func launch(_ path: String, _ args: [String]) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try? process.run()
    }

    /// Run an AppleScript. Returns nil if osascript failed, was denied Automation access, or hung.
    static func osascript(_ source: String, timeout: TimeInterval = 10) -> String? {
        let (status, output) = Shell.run("/usr/bin/osascript", ["-e", source], timeout: timeout)
        guard status == 0 else { return nil }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Quote a string for interpolation into an AppleScript string literal.
    static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// Mutable state shared with a worker thread, handed back across a semaphore.
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
