import AppKit

/// Runs the shell commands behind command keywords.
///
/// The command line is the user's own text and runs as written. Arguments typed after the keyword
/// are never spliced into it: they arrive as "$1", "$2"… (and "$@"), with the whole text in
/// $GOTO_QUERY, so nothing typed in the search box can turn into extra shell syntax.
enum CommandRunner {
    struct Outcome {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
        /// Last non-empty line, for the completion notice.
        var lastLine: String {
            output.split(whereSeparator: \.isNewline).map { String($0).trimmed }.last { !$0.isEmpty } ?? ""
        }
    }

    private static let outputLimit = 64 * 1024

    static func arguments(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// POSIX single-quoting: the result is always one literal word.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs in a login zsh (so PATH from ~/.zprofile applies) in the home folder, without a window.
    @discardableResult
    static func runInBackground(_ cmd: ShellCommand, args text: String,
                                completion: @escaping (Outcome) -> Void) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // zsh -c SCRIPT NAME ARG1 ARG2… sets $0 = NAME and $1… = the arguments.
        process.arguments = ["-lc", cmd.command, cmd.phrase.trimmed] + arguments(from: text)
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["GOTO_QUERY"] = text.trimmed
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let lock = NSLock()
        var buffer = Data()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock()
            if buffer.count < outputLimit { buffer.append(chunk.prefix(outputLimit - buffer.count)) }
            lock.unlock()
        }
        process.terminationHandler = { p in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            if buffer.count < outputLimit { buffer.append(rest.prefix(outputLimit - buffer.count)) }
            let output = String(decoding: buffer, as: UTF8.self)
            lock.unlock()
            let outcome = Outcome(status: p.terminationStatus, output: output)
            DispatchQueue.main.async { completion(outcome) }
        }
        do {
            try process.run()
            return process
        } catch {
            completion(Outcome(status: -1, output: error.localizedDescription))
            return nil
        }
    }

    /// Every process started under `pid` (children, grandchildren…), deepest last.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [pid]
        var buffer = [pid_t](repeating: 0, count: 4096)
        while let parent = queue.popLast() {
            let count = buffer.withUnsafeMutableBytes { raw in
                proc_listchildpids(parent, raw.baseAddress, Int32(raw.count))
            }
            guard count > 0 else { continue }
            for child in buffer.prefix(Int(count)) where child > 0 && !found.contains(child) {
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }

    /// Stops a command and everything it started: SIGTERM to the whole tree (children first),
    /// then SIGKILL to anything still alive after 3 seconds.
    static func terminateTree(_ pid: pid_t) {
        let tree = [pid] + descendants(of: pid)
        for p in tree.reversed() { kill(p, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            for p in tree.reversed() where kill(p, 0) == 0 { kill(p, SIGKILL) }
        }
    }

    /// The throwaway script a Terminal window runs. Arguments are single-quoted into `set --`.
    static func terminalScript(_ cmd: ShellCommand, args text: String) -> String {
        let quotedArgs = arguments(from: text).map(shellQuote).joined(separator: " ")
        return """
        #!/bin/zsh -l
        rm -f -- "$0"
        cd ~
        export GOTO_QUERY=\(shellQuote(text.trimmed))
        set -- \(quotedArgs)
        \(cmd.command)

        """
    }

    /// Opens a Terminal window running the command. A throwaway .command script in the per-user
    /// temporary folder carries it there (no Automation permission needed); it deletes itself first thing.
    static func runInTerminal(_ cmd: ShellCommand, args text: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("goto-\(UUID().uuidString).command")
        try Data(terminalScript(cmd, args: text).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: config)
    }
}
