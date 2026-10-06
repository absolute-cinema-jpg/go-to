import AppKit

extension String {
    var expandingTilde: String {
        if self == "~" { return NSHomeDirectory() }
        if hasPrefix("~/") { return NSHomeDirectory() + dropFirst() }
        return self
    }

    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }

    var nfc: String { precomposedStringWithCanonicalMapping }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

@inline(__always) func asciiLowerByte(_ b: UInt8) -> UInt8 { (b &- 65) < 26 ? b | 0x20 : b }
func asciiLower(_ bytes: [UInt8]) -> [UInt8] { bytes.map(asciiLowerByte) }
func queryBytes(_ s: String) -> [UInt8] { asciiLower(Array(s.nfc.utf8)) }

// MARK: - FNV-1a hashing (stable across launches, unlike Hasher)

let fnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325
let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

@inline(__always) func fnvStep(_ h: UInt64, _ b: UInt8) -> UInt64 { (h ^ UInt64(b)) &* fnvPrime }

func fnv1a<S: Sequence>(_ bytes: S, seed: UInt64 = fnvOffset) -> UInt64 where S.Element == UInt8 {
    var h = seed
    for b in bytes { h = fnvStep(h, b) }
    return h
}

func pathHash(_ path: String) -> UInt64 { fnv1a(path.nfc.utf8) }

// MARK: - Locations

enum Paths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("GoTo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()
    static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    /// Both are AES-GCM encrypted; see SecureStore.
    static var historyFile: URL { supportDir.appendingPathComponent("history.enc") }
    static var indexCache: URL { supportDir.appendingPathComponent("index.enc") }
    /// Plaintext files written by version 1.0, migrated or removed on launch.
    static var legacyHistoryFile: URL { supportDir.appendingPathComponent("history.json") }
    static var legacyIndexCache: URL { supportDir.appendingPathComponent("index.bin") }
}

// MARK: - Formatting

enum Fmt {
    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func count(_ n: Int) -> String { intFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }

    static func relative(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 45 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func duration(_ t: TimeInterval) -> String {
        t < 1 ? "\(Int(t * 1000)) ms" : String(format: "%.1f s", t)
    }
}

/// Thread-safe cancellation flag shared between the main thread and workers.
final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(for path: String) -> NSImage {
        if let img = cache.object(forKey: path as NSString) { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: path as NSString)
        return img
    }
}
