#if GOTO_DEVTOOLS
import AppKit
import CryptoKit

/// `goto-tools --search [--root DIR]... [--kp PHRASE=PATH]... QUERY...`  index + query benchmark
/// `goto-tools --snapshot OUT.png [--root DIR]... [QUERY]`  render the panel to an image
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
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--root" where i + 1 < args.count: roots.append(args[i + 1]); i += 2; continue
            case "--snapshot" where i + 1 < args.count: snapshot = args[i + 1]; i += 2; continue
            case "--kp" where i + 1 < args.count:
                let parts = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { keyphrases.append(Keyphrase(phrase: parts[0], path: parts[1])) }
                i += 2; continue
            case "--search": i += 1; continue
            default: queries.append(args[i]); i += 1
            }
        }
        var config = ConfigStore.load().0
        if !roots.isEmpty { config.searchRoots = roots }
        config.keyphrases += keyphrases

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
                                includeHidden: config.includeHidden, indexSettings: IndexSettings(config: config))

        if let snapshot {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let panel = SearchPanelController(engine: engine) { ctx }
            panel.setStatus("\(Fmt.count(index.count)) items")
            panel.renderSnapshot(query: queries.first ?? "", to: URL(fileURLWithPath: snapshot))
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

        print("URL scheme")
        let q = AppDelegate.sanitizedQuery("a\nb\u{0}c\u{7}" + String(repeating: "x", count: 500))
        check(q.hasPrefix("abc") && q.count == 200 && !q.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) },
              "pre-filled query stripped of control characters and capped at 200")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0
    }
}
#endif
