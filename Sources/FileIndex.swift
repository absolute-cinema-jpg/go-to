import Foundation

/// One file or folder. Names live in a shared byte buffer; paths are rebuilt by walking `parent`.
struct IndexEntry {
    var parent: Int32
    var nameOffset: UInt32
    var nameLength: UInt16
    var flags: UInt8
    var depth: UInt8
}

enum EntryFlag {
    static let directory: UInt8 = 1
    static let package: UInt8 = 2
}

struct IndexSettings {
    var roots: [String] = []
    var excludedNames: Set<String> = []
    var excludedPaths: Set<String> = []
    var includeHidden = false
    var signature: UInt64 = 0

    init(config: AppConfig) {
        var roots: [String] = []
        for r in config.searchRoots {
            let p = (r.trimmed.expandingTilde as NSString).standardizingPath
            if !p.isEmpty && p != "/" && !roots.contains(p) { roots.append(p) }
        }
        // Drop roots nested inside other roots.
        self.roots = roots.filter { r in !roots.contains { $0 != r && r.hasPrefix($0 + "/") } }
        for ex in config.excludes {
            let t = ex.trimmed
            if t.isEmpty { continue }
            if t.contains("/") {
                excludedPaths.insert((t.expandingTilde as NSString).standardizingPath)
            } else {
                excludedNames.insert(t)
            }
        }
        excludedPaths.insert(Paths.supportDir.path)
        includeHidden = config.includeHidden
        signature = fnv1a(config.indexSignature.utf8)
    }

    /// Whether a filesystem change at `path` could affect the index.
    func isRelevant(_ path: String) -> Bool {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        for ex in excludedPaths where p == ex || p.hasPrefix(ex + "/") { return false }
        for comp in p.split(separator: "/") {
            if !includeHidden && comp.hasPrefix(".") { return false }
            if excludedNames.contains(String(comp)) { return false }
        }
        return true
    }
}

final class FileIndex {
    let entries: [IndexEntry]
    let names: [UInt8]
    let lower: [UInt8]
    let pathHashes: [UInt64]
    let rootParents: [Int32: String]
    let builtAt: Date
    let buildDuration: TimeInterval
    let signature: UInt64

    var count: Int { entries.count }

    init(entries: [IndexEntry], names: [UInt8], rootParents: [Int32: String],
         builtAt: Date, buildDuration: TimeInterval, signature: UInt64) {
        self.entries = entries
        self.names = names
        self.rootParents = rootParents
        self.builtAt = builtAt
        self.buildDuration = buildDuration
        self.signature = signature
        lower = asciiLower(names)

        // Entries are stored pre-order, so a parent's hash is always ready before its children.
        var hashes = [UInt64](repeating: 0, count: entries.count)
        names.withUnsafeBufferPointer { nb in
            entries.withUnsafeBufferPointer { eb in
                for i in 0..<eb.count {
                    let e = eb[i]
                    var h = e.parent < 0 ? fnv1a((rootParents[Int32(i)] ?? "").utf8) : hashes[Int(e.parent)]
                    h = fnvStep(h, 47)
                    let start = Int(e.nameOffset)
                    for k in start..<(start + Int(e.nameLength)) { h = fnvStep(h, nb[k]) }
                    hashes[i] = h
                }
            }
        }
        pathHashes = hashes
    }

    func name(at i: Int) -> String {
        let e = entries[i]
        let start = Int(e.nameOffset)
        return names.withUnsafeBufferPointer {
            String(decoding: UnsafeBufferPointer(rebasing: $0[start..<(start + Int(e.nameLength))]), as: UTF8.self)
        }
    }

    func path(at i: Int) -> String {
        var comps: [String] = []
        var cur = Int32(i)
        var root = cur
        while cur >= 0 {
            comps.append(name(at: Int(cur)))
            root = cur
            cur = entries[Int(cur)].parent
        }
        return (rootParents[root] ?? "") + "/" + comps.reversed().joined(separator: "/")
    }

    func isDirectory(_ i: Int) -> Bool { entries[i].flags & EntryFlag.directory != 0 }
    func isPackage(_ i: Int) -> Bool { entries[i].flags & EntryFlag.package != 0 }
}

// MARK: - Building

enum IndexBuilder {
    /// Walks every root with fts(3). Returns nil if cancelled.
    static func build(_ settings: IndexSettings, progress: ((Int) -> Void)?, isCancelled: () -> Bool) -> FileIndex? {
        let started = Date()
        var entries: [IndexEntry] = []
        entries.reserveCapacity(250_000)
        var names: [UInt8] = []
        names.reserveCapacity(5_000_000)
        var rootParents: [Int32: String] = [:]
        let checkPaths = !settings.excludedPaths.isEmpty

        for root in settings.roots {
            guard FileManager.default.fileExists(atPath: root) else { continue }
            guard let rootC = strdup(root) else { continue }
            defer { free(rootC) }
            let argv: [UnsafeMutablePointer<CChar>?] = [rootC, nil]
            guard let fts = argv.withUnsafeBufferPointer({ fts_open($0.baseAddress, FTS_PHYSICAL | FTS_NOCHDIR | FTS_NOSTAT, nil) }) else { continue }
            defer { fts_close(fts) }

            while let ent = fts_read(fts) {
                if entries.count & 2047 == 0 {
                    if isCancelled() { return nil }
                    if entries.count & 8191 == 0 { progress?(entries.count) }
                }
                let info = Int32(ent.pointee.fts_info)
                if info == FTS_DP || info == FTS_DC { continue }
                let level = Int(ent.pointee.fts_level)

                let pathPtr = UnsafeRawPointer(ent.pointee.fts_path!).assumingMemoryBound(to: UInt8.self)
                var plen = Int(ent.pointee.fts_pathlen)
                while plen > 1 && pathPtr[plen - 1] == 47 { plen -= 1 }
                var start = plen
                while start > 0 && pathPtr[start - 1] != 47 { start -= 1 }
                let name = UnsafeBufferPointer(start: pathPtr + start, count: plen - start)
                if name.isEmpty { continue }

                let isDir = info == FTS_D || info == FTS_DNR
                var flags: UInt8 = isDir ? EntryFlag.directory : 0

                if level > 0 {
                    if !settings.includeHidden && name[0] == 46 {
                        if isDir { fts_set(fts, ent, FTS_SKIP) }
                        continue
                    }
                    if name.contains(13) { // "Icon\r" custom-icon files
                        if isDir { fts_set(fts, ent, FTS_SKIP) }
                        continue
                    }
                    if isDir {
                        let nameStr = String(decoding: name, as: UTF8.self)
                        if settings.excludedNames.contains(nameStr) {
                            fts_set(fts, ent, FTS_SKIP)
                            continue
                        }
                        if checkPaths {
                            let full = String(decoding: UnsafeBufferPointer(start: pathPtr, count: plen), as: UTF8.self)
                            if settings.excludedPaths.contains(full) {
                                fts_set(fts, ent, FTS_SKIP)
                                continue
                            }
                        }
                        // Bundles (.app, .photoslibrary, .xcodeproj, ...) are treated as single items.
                        if name.dropFirst().contains(46) {
                            let url = URL(fileURLWithFileSystemRepresentation: ent.pointee.fts_path, isDirectory: true, relativeTo: nil)
                            if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
                                flags = EntryFlag.package
                                fts_set(fts, ent, FTS_SKIP)
                            }
                        }
                    }
                }

                let idx = Int32(entries.count)
                let parent: Int32 = level == 0 ? -1 : Int32(truncatingIfNeeded: ent.pointee.fts_parent.pointee.fts_number)
                if isDir { ent.pointee.fts_number = Int(idx) }

                let offset = UInt32(names.count)
                if name.contains(where: { $0 >= 0x80 }) {
                    names.append(contentsOf: String(decoding: name, as: UTF8.self).nfc.utf8)
                } else {
                    names.append(contentsOf: name)
                }
                let length = UInt16(min(names.count - Int(offset), Int(UInt16.max)))
                entries.append(IndexEntry(parent: parent, nameOffset: offset, nameLength: length,
                                          flags: flags, depth: UInt8(min(level, 255))))
                if level == 0 {
                    let parentPath = (root as NSString).deletingLastPathComponent
                    rootParents[idx] = parentPath == "/" ? "" : parentPath
                }
            }
        }
        progress?(entries.count)
        return FileIndex(entries: entries, names: names, rootParents: rootParents,
                         builtAt: Date(), buildDuration: Date().timeIntervalSince(started),
                         signature: settings.signature)
    }
}

// MARK: - Persistence

extension FileIndex {
    private static let magic = Array("GOTOIDX2".utf8)

    /// Binary form of the index. Written to disk only through SecureStore (encrypted).
    func serialized() -> Data {
        Self.serialize(entries: entries, names: names, rootParents: rootParents,
                       builtAt: builtAt, buildDuration: buildDuration, signature: signature)
    }

    static func serialize(entries: [IndexEntry], names: [UInt8], rootParents: [Int32: String],
                          builtAt: Date, buildDuration: TimeInterval, signature: UInt64) -> Data {
        var data = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: magic)
        put(UInt32(MemoryLayout<IndexEntry>.stride))
        put(UInt32(entries.count))
        put(UInt32(names.count))
        put(UInt32(rootParents.count))
        put(builtAt.timeIntervalSince1970)
        put(buildDuration)
        put(signature)
        for (k, v) in rootParents {
            put(k)
            let b = Array(v.utf8)
            put(UInt32(b.count))
            data.append(contentsOf: b)
        }
        entries.withUnsafeBufferPointer { data.append($0) }
        data.append(contentsOf: names)
        return data
    }

    /// Parses and fully validates serialized data; anything malformed is rejected rather than trusted.
    static func deserialize(_ data: Data) -> FileIndex? {
        data.withUnsafeBytes { raw -> FileIndex? in
            var o = 0
            func get<T>(_: T.Type) -> T? {
                guard o + MemoryLayout<T>.size <= raw.count else { return nil }
                let v = raw.loadUnaligned(fromByteOffset: o, as: T.self)
                o += MemoryLayout<T>.size
                return v
            }
            guard raw.count > magic.count, Array(raw[0..<magic.count]) == magic else { return nil }
            o = magic.count
            guard let stride = get(UInt32.self), Int(stride) == MemoryLayout<IndexEntry>.stride,
                  let entryCount = get(UInt32.self), let nameCount = get(UInt32.self),
                  let rootCount = get(UInt32.self), let built = get(Double.self),
                  let duration = get(Double.self), let signature = get(UInt64.self),
                  rootCount <= entryCount, built.isFinite, duration.isFinite else { return nil }

            var rootParents: [Int32: String] = [:]
            for _ in 0..<rootCount {
                guard let k = get(Int32.self), let len = get(UInt32.self), Int(len) <= 4096,
                      o + Int(len) <= raw.count else { return nil }
                let bytes = raw[o..<(o + Int(len))]
                guard !bytes.contains(0), bytes.isEmpty || bytes.first == 47 else { return nil }
                rootParents[k] = String(decoding: bytes, as: UTF8.self)
                o += Int(len)
            }
            let count = Int(entryCount)
            let entryBytes = count * Int(stride)
            guard o + entryBytes + Int(nameCount) == raw.count else { return nil }
            let entries = [IndexEntry](unsafeUninitializedCapacity: count) { buf, n in
                if entryBytes > 0 { memcpy(buf.baseAddress!, raw.baseAddress! + o, entryBytes) }
                n = count
            }
            o += entryBytes
            let names = [UInt8](raw[o..<(o + Int(nameCount))])
            guard validate(entries, names, rootParents) else { return nil }
            return FileIndex(entries: entries, names: names, rootParents: rootParents,
                             builtAt: Date(timeIntervalSince1970: built), buildDuration: duration,
                             signature: signature)
        }
    }

    /// Every name in bounds and free of "/" and NUL; every parent an earlier directory one level up;
    /// every root registered. Guarantees the scorer and path(at:) can't read out of bounds or loop.
    private static func validate(_ entries: [IndexEntry], _ names: [UInt8], _ rootParents: [Int32: String]) -> Bool {
        for (k, _) in rootParents {
            guard k >= 0, Int(k) < entries.count, entries[Int(k)].parent == -1 else { return false }
        }
        return entries.withUnsafeBufferPointer { eb in
            names.withUnsafeBufferPointer { nb in
                for i in 0..<eb.count {
                    let e = eb[i]
                    let start = Int(e.nameOffset), len = Int(e.nameLength)
                    guard len > 0, start + len <= nb.count, e.flags & ~(EntryFlag.directory | EntryFlag.package) == 0 else { return false }
                    for b in nb[start..<(start + len)] where b == 0 || b == 47 { return false }
                    if e.parent == -1 {
                        guard e.depth == 0, rootParents[Int32(i)] != nil else { return false }
                    } else {
                        let p = Int(e.parent)
                        guard p >= 0, p < i, eb[p].flags & EntryFlag.directory != 0,
                              e.depth == (eb[p].depth == 255 ? 255 : eb[p].depth + 1) else { return false }
                    }
                }
                return true
            }
        }
    }
}

// MARK: - Live updates

final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(paths: [String], latency: TimeInterval = 2.0, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        ctx.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handler(paths)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}

/// Owns the current index: loads the cache, rebuilds in the background, reacts to file changes.
final class IndexManager: ObservableObject {
    @Published private(set) var itemCount = 0
    @Published private(set) var lastBuilt: Date?
    @Published private(set) var lastDuration: TimeInterval = 0
    @Published private(set) var isBuilding = false
    @Published private(set) var progressCount = 0

    private(set) var index: FileIndex?
    private var settings: IndexSettings
    private var cancelFlag: CancelFlag?
    private var dirty = false
    private var watcher: FSWatcher?
    private var rebuildTimer: Timer?
    var onIndexChanged: (() -> Void)?

    init(config: AppConfig) {
        settings = IndexSettings(config: config)
    }

    func start() {
        let sig = settings.signature
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.removeItem(at: Paths.legacyIndexCache) // plaintext cache from v1.0
            let cached = SecureStore.read(from: Paths.indexCache).flatMap(FileIndex.deserialize)
            DispatchQueue.main.async {
                if let cached, cached.signature == sig, self.index == nil {
                    self.install(cached)
                }
                self.rebuild()
            }
        }
        startWatcher()
    }

    func update(config: AppConfig) {
        let new = IndexSettings(config: config)
        guard new.signature != settings.signature else { return }
        settings = new
        startWatcher()
        rebuild()
    }

    func rebuild() {
        cancelFlag?.cancel()
        let flag = CancelFlag()
        cancelFlag = flag
        rebuildTimer?.invalidate()
        rebuildTimer = nil
        dirty = false
        isBuilding = true
        progressCount = 0
        let s = settings
        DispatchQueue.global(qos: .utility).async {
            let built = IndexBuilder.build(s, progress: { n in
                DispatchQueue.main.async { if flag === self.cancelFlag { self.progressCount = n } }
            }, isCancelled: { flag.isCancelled })
            guard let built else { return }
            SecureStore.write(built.serialized(), to: Paths.indexCache)
            DispatchQueue.main.async {
                guard flag === self.cancelFlag else { return }
                self.isBuilding = false
                self.install(built)
            }
        }
    }

    /// Called when the search panel opens: catch up on any changes that happened since the last scan.
    func panelWillShow() {
        if dirty && !isBuilding { rebuild() }
    }

    private func install(_ idx: FileIndex) {
        index = idx
        itemCount = idx.count
        lastBuilt = idx.builtAt
        lastDuration = idx.buildDuration
        onIndexChanged?()
    }

    private func startWatcher() {
        watcher = FSWatcher(paths: settings.roots) { [weak self] paths in
            guard let self else { return }
            if paths.contains(where: { self.settings.isRelevant($0) }) { self.noteChange() }
        }
    }

    private func noteChange() {
        dirty = true
        guard rebuildTimer == nil else { return }
        // Debounce bursts of changes, and avoid rescanning more than once a minute.
        let sinceLast = Date().timeIntervalSince(lastBuilt ?? .distantPast)
        let delay = max(5, 60 - sinceLast)
        rebuildTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.rebuildTimer = nil
            if self.dirty && !self.isBuilding { self.rebuild() }
        }
    }
}
