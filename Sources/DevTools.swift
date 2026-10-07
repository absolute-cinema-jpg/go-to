#if GOTO_DEVTOOLS
import AppKit
import CryptoKit

/// `goto-tools --search [--root DIR]... [--kp PHRASE=PATH]... [--cmd WORD=COMMAND]... QUERY...`  index + query benchmark
/// `goto-tools --snapshot OUT.png [--root DIR]... [--display-home DIR] [--padded] [--no-user-config] [QUERY]`  render the panel to an image
/// `goto-tools --make-iconset DIR`  render the app icon
/// `goto-tools --selftest`  check the security hardening (exit status 1 on failure)
enum DevTools {
    static func run(_ args: [String]) {
        if let i = args.firstIndex(of: "--make-iconset"), i + 1 < args.count {
            AppIcon.writeIconset(to: args[i + 1])
            return
        }
        if args.contains("--selftest") { exit(selfTest() ? 0 : 1) }
        guard args.contains("--search") || args.contains("--snapshot") else {
            print("usage: goto-tools --selftest|--search|--snapshot OUT.png|--make-iconset DIR [--root DIR]... [--kp PHRASE=PATH]... [QUERY]...")
            return
        }
        var roots: [String] = []
        var queries: [String] = []
        var snapshot: String?
        var keyphrases: [Keyphrase] = []
        var commands: [ShellCommand] = []
        var padded = false
        var userConfig = true
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--root" where i + 1 < args.count: roots.append(args[i + 1]); i += 2; continue
            case "--snapshot" where i + 1 < args.count: snapshot = args[i + 1]; i += 2; continue
            case "--display-home" where i + 1 < args.count:
                DisplayHome.path = (args[i + 1] as NSString).standardizingPath; i += 2; continue
            case "--padded": padded = true; i += 1; continue
            case "--no-user-config": userConfig = false; i += 1; continue
            case "--kp" where i + 1 < args.count:
                let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { keyphrases.append(Keyphrase(phrase: parts[0], path: parts[1])) }
                i += 2; continue
            case "--cmd" where i + 1 < args.count:
                let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { commands.append(ShellCommand(phrase: parts[0], command: parts[1])) }
                i += 2; continue
            case "--search": i += 1; continue
            default: queries.append(args[i]); i += 1
            }
        }
        // --no-user-config: defaults only, so demos never pick up your own keyphrases or paths.
        var config = userConfig ? ConfigStore.load().0 : AppConfig()
        if !roots.isEmpty { config.searchRoots = roots }
        config.keyphrases += keyphrases
        config.commands += commands

        let t0 = Date()
        guard let index = IndexBuilder.build(IndexSettings(config: config), progress: nil, isCancelled: { false }) else { return }
        print("Indexed \(Fmt.count(index.count)) items in \(Fmt.duration(Date().timeIntervalSince(t0)))")

        // Round-trip through the cache format in memory (nothing written to disk).
        let t1 = Date()
        let reloaded = FileIndex.deserialize(index.serialized())
        print("Cache round-trip: \(reloaded.map { Fmt.count($0.count) } ?? "REJECTED") items, \(Fmt.duration(Date().timeIntervalSince(t1)))")
        if let r = reloaded, r.count > 0 {
            let probe = r.count / 2
            print("  path check: \(r.path(at: probe) == index.path(at: probe) ? "ok" : "MISMATCH") — \(r.path(at: probe))")
        }

        let engine = SearchEngine()
        let ctx = SearchContext(index: index, keyphrases: config.keyphrases, historyBonus: [:], recent: [],
                                includeHidden: config.includeHidden, indexSettings: IndexSettings(config: config),
                                commands: config.commands)

        if let snapshot {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let panel = SearchPanelController(engine: engine) { ctx }
            panel.setStatus("\(Fmt.count(index.count)) items")
            panel.renderSnapshot(query: queries.first ?? "", to: URL(fileURLWithPath: snapshot), padding: padded ? 44 : 0)
            print("Wrote \(snapshot)")
            return
        }

        for q in queries {
            // Simulate typing the query one character at a time.
            var typing: [Double] = []
            for n in 1...max(1, q.count) {
                let t = Date()
                _ = engine.searchSync(String(q.prefix(n)), context: ctx)
                typing.append(Date().timeIntervalSince(t) * 1000)
            }
            let t = Date()
            let out = engine.searchSync(q, context: ctx)
            let ms = Date().timeIntervalSince(t) * 1000
            print("\n“\(q)”  mode=\(out.mode)  matches=\(Fmt.count(out.totalMatches))  cold=\(String(format: "%.1f", ms))ms  typing=[\(typing.map { String(format: "%.1f", $0) }.joined(separator: " "))]ms")
            for r in out.results {
                let kind = r.isDirectory ? "dir " : (r.isPackage ? "pkg " : "file")
                let kp = r.keyphrase.map { " [kp: \($0)]" } ?? ""
                print(String(format: "  %8d  ", r.score) + "\(kind)  \(r.path.abbreviatingHome)\(kp)")
            }
        }
    }

    // MARK: - Self-test

    static func selfTest() -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print((ok ? "  ok    " : "  FAIL  ") + name)
            if !ok { failures += 1 }
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("goto-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        print("Encrypted storage")
        let key = SymmetricKey(size: .bits256)
        let secret = Data("/Users/me/Documents/Tax Return 2026.pdf".utf8)
        let sealed = SecureStore.seal(secret, key: key) ?? Data()
        check(SecureStore.open(sealed, key: key) == secret, "AES-GCM round trip")
        check(sealed.range(of: Data("Tax Return".utf8)) == nil, "ciphertext contains no plaintext")
        var flipped = sealed
        flipped[flipped.count / 2] ^= 0x01
        check(SecureStore.open(flipped, key: key) == nil, "tampered file rejected")
        check(SecureStore.open(sealed, key: SymmetricKey(size: .bits256)) == nil, "wrong key rejected")

        print("Index cache validation")
        let tree = tmp.appendingPathComponent("tree")
        for dir in ["a/b/c", "Icon\r/inner", "x y/ü n i c ö d e"] {
            try? fm.createDirectory(at: tree.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for f in ["a/one.txt", "a/b/two.md", "Icon\r/inner/three", "x y/four"] {
            fm.createFile(atPath: tree.appendingPathComponent(f).path, contents: Data())
        }
        var cfg = AppConfig()
        cfg.searchRoots = [tree.path]
        cfg.excludes = []
        guard let idx = IndexBuilder.build(IndexSettings(config: cfg), progress: nil, isCancelled: { false }) else {
            check(false, "index builds")
            return false
        }
        let data = idx.serialized()
        check(FileIndex.deserialize(data)?.count == idx.count, "valid index accepted (\(idx.count) items)")
        check(!(0..<idx.count).contains { idx.path(at: $0).contains("Icon\r") }, "children of skipped folders not misattached")
        check(FileIndex.deserialize(data.dropLast()) == nil, "truncated file rejected")
        check(FileIndex.deserialize(data + Data([0])) == nil, "trailing bytes rejected")

        func forged(_ entries: [IndexEntry], names: String = "rootkid", roots: [Int32: String] = [0: "/tmp"]) -> Bool {
            let bytes = FileIndex.serialize(entries: entries, names: Array(names.utf8), rootParents: roots,
                                            builtAt: Date(), buildDuration: 0, signature: 0)
            return FileIndex.deserialize(bytes) == nil
        }
        let root = IndexEntry(parent: -1, nameOffset: 0, nameLength: 4, flags: EntryFlag.directory, depth: 0)
        let kid = IndexEntry(parent: 0, nameOffset: 4, nameLength: 3, flags: 0, depth: 1)
        check(!forged([root, kid]), "well-formed forged index accepted (control)")
        check(forged([root, IndexEntry(parent: 1, nameOffset: 4, nameLength: 3, flags: 0, depth: 1)]), "self-parent (loop) rejected")
        check(forged([root, IndexEntry(parent: 7, nameOffset: 4, nameLength: 3, flags: 0, depth: 1)]), "out-of-range parent rejected")
        check(forged([root, IndexEntry(parent: 0, nameOffset: 4, nameLength: 900, flags: 0, depth: 1)]), "out-of-bounds name rejected")
        check(forged([root, kid], names: "root/id"), "name containing / rejected")
        check(forged([IndexEntry(parent: -1, nameOffset: 0, nameLength: 4, flags: 0, depth: 0), kid]), "child of a file rejected")
        check(forged([root, kid], roots: [:]), "unregistered root rejected")
        check(forged([root, kid], roots: [0: "relative/path"]), "relative root rejected")

        var accepted = 0
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            var d = data
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
            if let f = FileIndex.deserialize(d) {
                accepted += 1
                for i in 0..<f.count { _ = f.path(at: i); _ = f.name(at: i) }
                _ = SearchEngine().searchSync("o", context: SearchContext(index: f, keyphrases: [], historyBonus: [:], recent: [], includeHidden: false))
            }
        }
        check(true, "5,000 random corruptions: no crash (\(accepted) harmless variants accepted and searched)")

        print("Finder script")
        check(FinderRevealer.scriptCompiles, "reveal script compiles")
        let echo = NSAppleScript(source: "on echoArgs(a, b, c)\n return a & \"|\" & b & \"|\" & (c as text)\nend echoArgs")!
        var err: NSDictionary?
        echo.compileAndReturnError(&err)
        let hostile = [
            "a\" & (do shell script \"touch /tmp/pwned\") & \"",
            "b\\\" & (do shell script \"touch /tmp/pwned\") & \"",
            "c“ & (do shell script \"touch /tmp/pwned\") & ”",
            "d\n\r\" & «event sysoexec» \"touch /tmp/pwned\"",
            "e\u{0}f",
        ]
        var allSafe = true
        for h in hostile {
            var e: NSDictionary?
            let r = FinderRevealer.callHandler("echoArgs", in: echo, with: [.init(string: h), .init(string: "/p"), .init(boolean: true)], error: &e)
            if r?.stringValue != h + "|/p|true" { allSafe = false; print("        mismatch for \(h.debugDescription): \(String(describing: r?.stringValue)) \(e ?? [:])") }
        }
        check(allSafe, "hostile file names passed through as plain data (\(hostile.count) cases)")

        print("⌘↵ launch safety")
        func make(_ name: String, executable: Bool = false, dir: Bool = false) -> String {
            let p = tmp.appendingPathComponent(name).path
            if dir { try? fm.createDirectory(atPath: p, withIntermediateDirectories: true) } else { fm.createFile(atPath: p, contents: Data("x".utf8)) }
            if executable { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p) }
            return p
        }
        check(LaunchSafety.riskDescription(for: make("notes.txt")) == nil, "plain document opens without asking")
        check(LaunchSafety.riskDescription(for: make("report.pdf")) == nil, "PDF opens without asking")
        check(LaunchSafety.riskDescription(for: make("Documents.command")) != nil, ".command script asks first")
        check(LaunchSafety.riskDescription(for: make("setup.pkg")) != nil, "installer asks first")
        check(LaunchSafety.riskDescription(for: make("run", executable: true)) != nil, "executable file asks first")
        check(LaunchSafety.riskDescription(for: make("Evil.app", dir: true)) != nil, "app outside /Applications asks first")
        check(LaunchSafety.riskDescription(for: "/System/Applications/Calculator.app") == nil, "system app opens without asking")

        print("Shell commands")
        let marker = tmp.appendingPathComponent("INJECTED").path
        let hostileArgs = "$(touch \(marker)) `touch \(marker)` ;touch \(marker) 'q\"uo\\te' &&x |y $HOME"
        let expected = CommandRunner.arguments(from: hostileArgs)
        let echoCmd = ShellCommand(phrase: "echo", command: #"printf '%s\n' "$@"; printf 'Q=%s\n' "$GOTO_QUERY""#)
        var outcome: CommandRunner.Outcome?
        CommandRunner.runInBackground(echoCmd, args: hostileArgs) { outcome = $0 }
        let deadline = Date().addingTimeInterval(15)
        while outcome == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let lines = outcome?.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        check(outcome?.succeeded == true && Array(lines.prefix(expected.count)) == expected,
              "background: arguments arrive as literal $1…$\(expected.count)")
        check(lines.contains("Q=" + hostileArgs.trimmed), "background: whole text arrives in $GOTO_QUERY")
        check(!fm.fileExists(atPath: marker), "background: nothing in the arguments was executed")

        let scriptURL = tmp.appendingPathComponent("t.command")
        try? Data(CommandRunner.terminalScript(echoCmd, args: hostileArgs).utf8).write(to: scriptURL)
        let zsh = Process()
        zsh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        zsh.arguments = [scriptURL.path]
        let pipe = Pipe()
        zsh.standardOutput = pipe
        zsh.standardError = pipe
        try? zsh.run()
        zsh.waitUntilExit()
        let tLines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        check(Array(tLines.prefix(expected.count)) == expected && tLines.contains("Q=" + hostileArgs.trimmed),
              "Terminal script: same literal arguments and $GOTO_QUERY")
        check(!fm.fileExists(atPath: marker), "Terminal script: nothing in the arguments was executed")
        check(!fm.fileExists(atPath: scriptURL.path), "Terminal script deletes itself")

        var failed: CommandRunner.Outcome?
        CommandRunner.runInBackground(ShellCommand(phrase: "f", command: "echo oops >&2; exit 3"), args: "") { failed = $0 }
        while failed == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(failed?.status == 3 && failed?.lastLine == "oops", "failing command reports exit code and last line")

        let pidFile = tmp.appendingPathComponent("child.pid").path
        var stoppedOutcome: CommandRunner.Outcome?
        let longRunning = CommandRunner.runInBackground(
            ShellCommand(phrase: "long", command: "sleep 60 & echo $! > \(CommandRunner.shellQuote(pidFile)); wait"),
            args: "") { stoppedOutcome = $0 }
        let started = Date()
        while !fm.fileExists(atPath: pidFile) && Date().timeIntervalSince(started) < 10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let childPid = pid_t((try? String(contentsOfFile: pidFile))?.trimmed ?? "") ?? 0
        let commandTree = longRunning.map { CommandRunner.descendants(of: $0.processIdentifier) } ?? []
        check(childPid > 0 && commandTree.contains(childPid), "process tree includes what the command started")
        if let p = longRunning { CommandRunner.terminateTree(p.processIdentifier) }
        while stoppedOutcome == nil && Date().timeIntervalSince(started) < 15 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        check(stoppedOutcome != nil && stoppedOutcome?.succeeded == false, "stop ends the command")
        var childGone = false
        for _ in 0..<100 where !childGone {
            childGone = kill(childPid, 0) != 0
            if !childGone { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        check(childGone, "stop also ends processes the command started")

        let cmdCtx = SearchContext(index: nil, keyphrases: [], historyBonus: [:], recent: [], includeHidden: false,
                                   commands: [ShellCommand(phrase: "flush", command: "true")])
        let exact = SearchEngine().searchSync("flush", context: cmdCtx)
        check(exact.mode == .command && exact.results.first?.command?.phrase == "flush", "exact keyword finds the command")
        check(SearchEngine().searchSync("fls", context: cmdCtx).results.first?.command != nil, "fuzzy keyword finds the command")

        print("URL scheme")
        let q = AppDelegate.sanitizedQuery("a\nb\u{0}c\u{7}" + String(repeating: "x", count: 500))
        check(q.hasPrefix("abc") && q.count == 200 && !q.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
              "pre-filled query stripped of control characters and capped at 200")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0
    }
}
#endif
