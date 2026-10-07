import Foundation

struct SearchResult {
    var path: String
    var name: String
    var isDirectory: Bool
    var isPackage: Bool
    var keyphrase: String?
    var score: Int
    /// UTF-8 byte offsets into `name` to highlight.
    var highlight: [Int] = []
    /// Found by typo-tolerant matching rather than as a fuzzy subsequence.
    var approximate = false
    /// Set for "pph tmp" searches, so locations can be shown relative to the keyphrase.
    var scope: (phrase: String, dir: String)?
    /// A command keyword rather than a file: running it passes `commandArgs` as arguments.
    var command: ShellCommand?
    var commandArgs = ""

    static func command(_ cmd: ShellCommand, args: String = "", score: Int) -> SearchResult {
        let args = args.trimmed
        var r = SearchResult(path: "", name: cmd.phrase.trimmed + (args.isEmpty ? "" : " " + args),
                             isDirectory: false, isPackage: false, keyphrase: nil, score: score)
        r.command = cmd
        r.commandArgs = args
        return r
    }
}

enum SearchMode: Equatable {
    case recent, fuzzy, keyphrase, path, approximate, none
    /// "pph tmp": searching inside the folder of keyphrase "pph".
    case scoped(String)
    /// The query is exactly a command keyword.
    case command
}

struct SearchOutput {
    let query: String
    let results: [SearchResult]
    let totalMatches: Int
    let mode: SearchMode
}

/// Immutable snapshot of everything a search needs, taken on the main thread.
struct SearchContext {
    let index: FileIndex?
    let keyphrases: [Keyphrase]
    let historyBonus: [UInt64: Int32]
    let recent: [String]
    let includeHidden: Bool
    /// Exclusion rules, applied when scanning a keyphrase folder that isn't in the main index.
    var indexSettings: IndexSettings?
    var commands: [ShellCommand] = []
}

final class SearchEngine {
    static let maxResults = 8
    private static let perChunkTop = 48
    private static let maxNameBytes = 1024

    private let queue = DispatchQueue(label: "goto.search", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    // Incremental narrowing: when the query only grows, rescan only the previous matches.
    private struct NarrowKey { let index: ObjectIdentifier; let range: Range<Int>?; let query: [UInt8]; let tokens: Int }
    private var narrowKey: NarrowKey?
    private var narrowCandidates: [Int32] = []
    private let scopes = ScopeCache()

    func search(_ query: String, context: SearchContext, completion: @escaping (SearchOutput) -> Void) {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let isStale = { [weak self] () -> Bool in
            guard let self else { return true }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.generation != gen
        }
        queue.async {
            guard !isStale(), let out = self.run(query, context, isCancelled: isStale), !isStale() else { return }
            DispatchQueue.main.async { completion(out) }
        }
    }

    func searchSync(_ query: String, context: SearchContext) -> SearchOutput {
        queue.sync { run(query, context, isCancelled: { false })! }
    }

    // MARK: - Core

    private func run(_ rawQuery: String, _ ctx: SearchContext, isCancelled: @escaping () -> Bool) -> SearchOutput? {
        let query = rawQuery.trimmed.nfc
        if query.isEmpty { return recents(rawQuery, ctx) }

        if query.hasPrefix("/") || query.hasPrefix("~") {
            return pathSearch(rawQuery, input: query, ctx, mode: .path)
        }
        // "pph/src" browses inside the target of keyphrase "pph".
        if let slash = query.firstIndex(of: "/") {
            let head = String(query[..<slash]).lowercased()
            if let kp = ctx.keyphrases.first(where: { $0.normalizedPhrase == head }) {
                return pathSearch(rawQuery, input: kp.path.expandingTilde + query[slash...], ctx, mode: .path)
            }
        }

        let collapsed = query.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let q = queryBytes(collapsed)
        let tokens = collapsed.split(separator: " ").map { queryBytes(String($0)) }

        // "pph tmp": a leading keyphrase limits the rest of the query to inside its folder.
        if tokens.count >= 2, !ctx.keyphrases.contains(where: { $0.normalizedPhrase == collapsed.lowercased() }) {
            let head = String(collapsed.prefix { $0 != " " }).lowercased()
            if let kp = ctx.keyphrases.first(where: { $0.normalizedPhrase == head }) {
                let dir = (kp.path.expandingTilde as NSString).standardizingPath
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                    let rest = String(collapsed.drop { $0 != " " }.dropFirst())
                    return scopedSearch(rawQuery, phrase: kp.phrase.trimmed, dir: dir, rest: rest, ctx, isCancelled: isCancelled)
                }
            }
        }

        var merged: [String: SearchResult] = [:]
        var exactKeyphrase = false

        for kp in ctx.keyphrases {
            let phrase = kp.normalizedPhrase
            if phrase.isEmpty { continue }
            let pb = asciiLower(Array(phrase.utf8))
            var score: Int
            if pb == q {
                score = 1_000_000
                exactKeyphrase = true
                prewarmScope(kp, ctx)
            } else {
                guard let s = scoreBytes(q, pb) else { continue }
                score = 150 + Int(s) + (pb.starts(with: q) ? 100 : 0)
            }
            let path = (kp.path.expandingTilde as NSString).standardizingPath
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            if !exists { score -= 500 }
            let name = (path as NSString).lastPathComponent.nfc
            let isPkg = isDir.boolValue && NSWorkspaceLite.isPackage(path)
            if let existing = merged[path], existing.score >= score { continue }
            merged[path] = SearchResult(path: path, name: name, isDirectory: isDir.boolValue && !isPkg,
                                        isPackage: isPkg, keyphrase: kp.phrase.trimmed, score: score)
        }

        // Command keywords compete like keyphrases; they're keyed apart from paths.
        var exactCommand = false
        for cmd in ctx.commands where !cmd.normalizedPhrase.isEmpty && !cmd.command.trimmed.isEmpty {
            let pb = asciiLower(Array(cmd.normalizedPhrase.utf8))
            var score: Int
            if pb == q {
                score = 1_000_000
                exactCommand = true
            } else {
                guard let s = scoreBytes(q, pb) else { continue }
                score = 150 + Int(s) + (pb.starts(with: q) ? 100 : 0)
            }
            merged["\u{1}command:" + cmd.id.uuidString] = .command(cmd, score: score)
        }

        var total = merged.count
        if let index = ctx.index {
            guard let res = searchIndex(index, q: q, tokens: tokens, ctx: ctx, isCancelled: isCancelled) else { return nil }
            let (top, matched) = res
            total += matched
            for (score, idx) in top {
                let i = Int(idx)
                let path = index.path(at: i)
                if var existing = merged[path] {
                    existing.score = max(existing.score, Int(score) + 150)
                    merged[path] = existing
                } else {
                    merged[path] = SearchResult(path: path, name: index.name(at: i), isDirectory: index.isDirectory(i),
                                                isPackage: index.isPackage(i), keyphrase: nil, score: Int(score))
                }
            }
        }

        // Scattered subsequence hits are weak evidence; let close typo matches compete with them.
        let best = merged.values.map(\.score).max() ?? Int.min
        if !exactKeyphrase && !exactCommand && ((merged.isEmpty && q.count >= 2) || (q.count >= 4 && best < 22 * q.count + 20)) {
            for r in approximate(q, ctx, index: ctx.index) where (merged[r.path]?.score ?? Int.min) < r.score {
                if merged[r.path] == nil { total += 1 }
                merged[r.path] = r
            }
        }

        var results = Array(merged.values)
        results.sort { $0.score != $1.score ? $0.score > $1.score : $0.path.count < $1.path.count }
        results = Array(results.prefix(Self.maxResults))
        var mode: SearchMode = exactKeyphrase ? .keyphrase : (exactCommand ? .command : .fuzzy)
        if results.isEmpty { mode = .none } else if results[0].approximate { mode = .approximate }
        highlight(&results, q, tokens)
        return SearchOutput(query: rawQuery, results: results, totalMatches: total, mode: mode)
    }

    private func highlight(_ results: inout [SearchResult], _ q: [UInt8], _ tokens: [[UInt8]]) {
        for k in results.indices where !results[k].approximate {
            let lowerName = queryBytes(results[k].name)
            let whole = lowerName.withUnsafeBufferPointer { s in q.withUnsafeBufferPointer { isSubsequence($0, s) } }
            results[k].highlight = fuzzyPositions(whole ? q : (tokens.last ?? q), in: results[k].name)
        }
    }

    // MARK: Keyphrase scopes

    /// Search only inside `dir`, using its slice of the main index or, if it isn't indexed
    /// (e.g. on another volume), a separate scan of just that folder.
    private func scopedSearch(_ raw: String, phrase: String, dir: String, rest: String,
                              _ ctx: SearchContext, isCancelled: @escaping () -> Bool) -> SearchOutput? {
        guard let scoped = scope(for: dir, ctx), !scoped.1.isEmpty else {
            return SearchOutput(query: raw, results: [], totalMatches: 0, mode: .scoped(phrase))
        }
        let (index, range) = scoped
        // The folder itself sits just before its contents (pre-order), so its children are one level deeper.
        let depthBase = Int(index.entries[range.lowerBound - 1].depth) + 1
        let q = queryBytes(rest)
        let tokens = rest.split(separator: " ").map { queryBytes(String($0)) }
        guard let found = searchIndex(index, q: q, tokens: tokens, ctx: ctx, range: range,
                                      depthBase: depthBase, isCancelled: isCancelled) else { return nil }
        let (top, matched) = found
        var results = top.map { score, idx -> SearchResult in
            let i = Int(idx)
            return SearchResult(path: index.path(at: i), name: index.name(at: i), isDirectory: index.isDirectory(i),
                                isPackage: index.isPackage(i), keyphrase: nil, score: Int(score))
        }
        var total = matched
        let best = results.map(\.score).max() ?? Int.min
        if (results.isEmpty && q.count >= 2) || (q.count >= 4 && best < 22 * q.count + 20) {
            var seen = Set(results.map(\.path))
            for r in approximate(q, ctx, index: index, range: range, depthBase: depthBase, includeKeyphrases: false)
            where seen.insert(r.path).inserted {
                results.append(r)
                total += 1
            }
        }
        results.sort { $0.score != $1.score ? $0.score > $1.score : $0.path.count < $1.path.count }
        results = Array(results.prefix(Self.maxResults))
        highlight(&results, q, tokens)
        for k in results.indices { results[k].scope = (phrase, dir.nfc) }
        return SearchOutput(query: raw, results: results, totalMatches: total, mode: .scoped(phrase))
    }

    private func scope(for dir: String, _ ctx: SearchContext) -> (FileIndex, Range<Int>)? {
        if let index = ctx.index, let range = index.subtree(of: dir) { return (index, range) }
        guard let settings = ctx.indexSettings, let mini = scopes.index(for: dir, settings: settings), mini.count > 0 else { return nil }
        return (mini, 1..<mini.count) // entry 0 is the folder itself
    }

    /// Typing a keyphrase on its own starts scanning its folder, so "pph tmp" is instant.
    private func prewarmScope(_ kp: Keyphrase, _ ctx: SearchContext) {
        guard let settings = ctx.indexSettings else { return }
        let dir = (kp.path.expandingTilde as NSString).standardizingPath
        if let index = ctx.index, index.subtree(of: dir) != nil { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return }
        scopes.prewarm(dir, settings: settings)
    }

    private func scoreBytes(_ q: [UInt8], _ s: [UInt8]) -> Int32? {
        guard s.count <= Self.maxNameBytes else { return nil }
        let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: 4 * max(s.count, 1))
        defer { scratch.deallocate() }
        return q.withUnsafeBufferPointer { qb in
            s.withUnsafeBufferPointer { sb in
                isSubsequence(qb, sb) ? fuzzyScore(qb, sb, sb, scratch) : nil
            }
        }
    }

    // MARK: Index scan

    private func searchIndex(_ index: FileIndex, q: [UInt8], tokens: [[UInt8]], ctx: SearchContext,
                             range: Range<Int>? = nil, depthBase: Int = 0,
                             isCancelled: @escaping () -> Bool) -> ([(Int32, Int32)], Int)? {
        let id = ObjectIdentifier(index)
        var candidates: [Int32]?
        if let key = narrowKey, key.index == id, key.range == range, key.tokens == tokens.count, q.starts(with: key.query),
           !q[key.query.count...].contains(32) {
            candidates = narrowCandidates
        }

        let start = range?.lowerBound ?? 0
        let total = candidates?.count ?? (range?.count ?? index.count)
        let chunkCount = max(1, min(64, total / 4096))
        let collector = ChunkCollector(count: chunkCount)
        let cancelled = CancelFlag()

        index.entries.withUnsafeBufferPointer { entries in
            index.lower.withUnsafeBufferPointer { lower in
                index.names.withUnsafeBufferPointer { names in
                    index.pathHashes.withUnsafeBufferPointer { hashes in
                        q.withUnsafeBufferPointer { qb in
                            let scorer = IndexScorer(entries: entries, lower: lower, names: names, hashes: hashes,
                                                     q: qb, tokens: tokens, history: ctx.historyBonus,
                                                     depthBase: Int32(depthBase))
                            let run = { (cands: UnsafeBufferPointer<Int32>?) in
                                DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                                    let lo = total * c / chunkCount, hi = total * (c + 1) / chunkCount
                                    let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: 4 * Self.maxNameBytes)
                                    defer { scratch.deallocate() }
                                    var top: [(Int32, Int32)] = []
                                    var matched: [Int32] = []
                                    for k in lo..<hi {
                                        if k & 1023 == 0 && (cancelled.isCancelled || isCancelled()) { cancelled.cancel(); return }
                                        let i = cands.map { Int($0[k]) } ?? (start + k)
                                        if let s = scorer.score(i, scratch) {
                                            matched.append(Int32(i))
                                            top.append((s, Int32(i)))
                                        }
                                    }
                                    if top.count > Self.perChunkTop {
                                        top.sort { $0.0 > $1.0 }
                                        top.removeSubrange(Self.perChunkTop...)
                                    }
                                    collector.set(c, top: top, matched: matched)
                                }
                            }
                            if let candidates {
                                candidates.withUnsafeBufferPointer { run($0) }
                            } else {
                                run(nil)
                            }
                        }
                    }
                }
            }
        }
        if cancelled.isCancelled { return nil }
        let matched = collector.matched.flatMap { $0 }
        narrowKey = NarrowKey(index: id, range: range, query: q, tokens: tokens.count)
        narrowCandidates = matched
        var top = collector.tops.flatMap { $0 }
        top.sort { $0.0 > $1.0 }
        return (Array(top.prefix(Self.maxResults * 3)), matched.count)
    }

    // MARK: Fallbacks

    private func recents(_ raw: String, _ ctx: SearchContext) -> SearchOutput {
        var results: [SearchResult] = []
        let fm = FileManager.default
        for path in ctx.recent {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            let pkg = isDir.boolValue && NSWorkspaceLite.isPackage(path)
            results.append(SearchResult(path: path, name: (path as NSString).lastPathComponent, isDirectory: isDir.boolValue && !pkg,
                                        isPackage: pkg, keyphrase: ctx.keyphrases.first { ($0.path.expandingTilde as NSString).standardizingPath == path }?.phrase,
                                        score: 0))
            if results.count == Self.maxResults { break }
        }
        return SearchOutput(query: raw, results: results, totalMatches: results.count, mode: .recent)
    }

    /// Live directory listing for queries that look like paths ("~/Doc", "/usr/lo", "pph/sub").
    private func pathSearch(_ raw: String, input: String, _ ctx: SearchContext, mode: SearchMode) -> SearchOutput {
        let full = input.expandingTilde
        let fm = FileManager.default
        let endsWithSlash = full.hasSuffix("/")
        let dir = endsWithSlash ? full : (full as NSString).deletingLastPathComponent
        let partial = endsWithSlash ? "" : (full as NSString).lastPathComponent
        let pq = queryBytes(partial)
        var results: [SearchResult] = []

        func make(_ path: String, score: Int) -> SearchResult {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)
            let pkg = isDir.boolValue && NSWorkspaceLite.isPackage(path)
            return SearchResult(path: path, name: (path as NSString).lastPathComponent.nfc,
                                isDirectory: isDir.boolValue && !pkg, isPackage: pkg, keyphrase: nil, score: score)
        }

        let exact = (full as NSString).standardizingPath
        if fm.fileExists(atPath: exact) {
            results.append(make(exact, score: 1_000_000))
        }
        if let contents = try? fm.contentsOfDirectory(atPath: dir.isEmpty ? "/" : dir) {
            for name in contents.prefix(5000) {
                if name.hasPrefix(".") && !partial.hasPrefix(".") && !ctx.includeHidden { continue }
                let nb = queryBytes(name)
                var score = 0
                if !pq.isEmpty {
                    guard let s = scoreBytes(pq, nb) else { continue }
                    score = Int(s)
                    if nb == pq { score += 80 } else if nb.starts(with: pq) { score += 25 }
                }
                let path = ((dir.isEmpty ? "/" : dir) as NSString).appendingPathComponent(name)
                if path == exact { continue }
                var r = make(path, score: score)
                if r.isDirectory { r.score += 10 }
                results.append(r)
            }
        }
        results.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let total = results.count
        results = Array(results.prefix(Self.maxResults))
        for k in results.indices where !pq.isEmpty && results[k].score < 1_000_000 {
            results[k].highlight = fuzzyPositions(pq, in: results[k].name)
        }
        return SearchOutput(query: raw, results: results, totalMatches: total, mode: results.isEmpty ? .none : mode)
    }

    /// Typo-tolerant matching ("documnets" -> "Documents"), scored on the same scale as fuzzy matches.
    private func approximate(_ q: [UInt8], _ ctx: SearchContext, index: FileIndex?, range: Range<Int>? = nil,
                             depthBase: Int = 0, includeKeyphrases: Bool = true) -> [SearchResult] {
        let qn = q.count
        guard qn >= 2 else { return [] }
        let maxDist = qn <= 3 ? 1 : (qn <= 7 ? 2 : 3)
        let base = 24 * qn + 12
        let buf = UnsafeMutablePointer<Int>.allocate(capacity: 3 * (Self.maxNameBytes + 2))
        defer { buf.deallocate() }
        var found: [SearchResult] = []

        func distance(_ s: UnsafeBufferPointer<UInt8>, _ qb: UnsafeBufferPointer<UInt8>, _ buf: UnsafeMutablePointer<Int>) -> Int {
            var d = editDistance(qb, s, maxDist: maxDist, buf)
            // Partial typing: compare against the start of the name too.
            if s.count > qn {
                d = min(d, editDistance(qb, UnsafeBufferPointer(rebasing: s[0..<qn]), maxDist: maxDist, buf) + 1)
            }
            if let dot = s.lastIndex(of: 46), dot > 0, dot != qn {
                d = min(d, editDistance(qb, UnsafeBufferPointer(rebasing: s[0..<dot]), maxDist: maxDist, buf))
            }
            return d
        }

        q.withUnsafeBufferPointer { qb in
            for kp in includeKeyphrases ? ctx.keyphrases : [] {
                let pb = asciiLower(Array(kp.normalizedPhrase.utf8))
                let d = pb.withUnsafeBufferPointer { distance($0, qb, buf) }
                guard d <= maxDist else { continue }
                let path = (kp.path.expandingTilde as NSString).standardizingPath
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                found.append(SearchResult(path: path, name: (path as NSString).lastPathComponent.nfc, isDirectory: isDir.boolValue,
                                          isPackage: false, keyphrase: kp.phrase.trimmed, score: base + 150 - 22 * d, approximate: true))
            }
            guard let index else { return }
            let start = range?.lowerBound ?? 0
            let n = range?.count ?? index.count
            let chunkCount = max(1, min(64, n / 8192))
            let collector = ChunkCollector(count: chunkCount)
            index.entries.withUnsafeBufferPointer { entries in
                index.lower.withUnsafeBufferPointer { lower in
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
                        let local = UnsafeMutablePointer<Int>.allocate(capacity: 3 * (Self.maxNameBytes + 2))
                        defer { local.deallocate() }
                        var top: [(Int32, Int32)] = []
                        for i in (start + n * c / chunkCount)..<(start + n * (c + 1) / chunkCount) {
                            let e = entries[i]
                            let len = Int(e.nameLength)
                            if len + maxDist < qn || len > Self.maxNameBytes { continue }
                            let s = UnsafeBufferPointer(rebasing: lower[Int(e.nameOffset)..<(Int(e.nameOffset) + len)])
                            let d = distance(s, qb, local)
                            if d > maxDist { continue }
                            var score = base - 22 * d - min(max(Int(e.depth) - depthBase, 0) * 2, 24) - min(max(len - qn, 0), 48) / 4
                            if e.flags & EntryFlag.directory != 0 { score += 10 }
                            if let h = ctx.historyBonus[index.pathHashes[i]] { score += Int(h) }
                            top.append((Int32(score), Int32(i)))
                        }
                        if top.count > Self.maxResults {
                            top.sort { $0.0 > $1.0 }
                            top.removeSubrange(Self.maxResults...)
                        }
                        collector.set(c, top: top, matched: [])
                    }
                }
            }
            let best = collector.tops.flatMap { $0 }.map { (Int($0.0), $0.1) }
            let sortedBest = best.sorted { $0.0 > $1.0 }
            for (score, idx) in sortedBest.prefix(Self.maxResults) {
                let i = Int(idx)
                found.append(SearchResult(path: index.path(at: i), name: index.name(at: i), isDirectory: index.isDirectory(i),
                                          isPackage: index.isPackage(i), keyphrase: nil, score: score, approximate: true))
            }
        }
        return found
    }
}

private final class ChunkCollector {
    private let lock = NSLock()
    var tops: [[(Int32, Int32)]]
    var matched: [[Int32]]
    init(count: Int) {
        tops = Array(repeating: [], count: count)
        matched = Array(repeating: [], count: count)
    }
    func set(_ c: Int, top: [(Int32, Int32)], matched m: [Int32]) {
        lock.lock()
        tops[c] = top
        matched[c] = m
        lock.unlock()
    }
}

/// Scores one index entry against the query. Pure function over raw buffers, safe to call concurrently.
private struct IndexScorer {
    let entries: UnsafeBufferPointer<IndexEntry>
    let lower: UnsafeBufferPointer<UInt8>
    let names: UnsafeBufferPointer<UInt8>
    let hashes: UnsafeBufferPointer<UInt64>
    let q: UnsafeBufferPointer<UInt8>
    let tokens: [[UInt8]]
    let history: [UInt64: Int32]
    /// Depth that counts as "top level" (non-zero when searching inside a keyphrase folder).
    let depthBase: Int32

    @inline(__always)
    private func slices(_ e: IndexEntry) -> (UnsafeBufferPointer<UInt8>, UnsafeBufferPointer<UInt8>) {
        let off = Int(e.nameOffset)
        let len = min(Int(e.nameLength), 1024)
        return (UnsafeBufferPointer(rebasing: lower[off..<(off + len)]),
                UnsafeBufferPointer(rebasing: names[off..<(off + len)]))
    }

    func score(_ i: Int, _ scratch: UnsafeMutablePointer<Int32>) -> Int32? {
        let e = entries[i]
        let (s, o) = slices(e)
        var base: Int32
        var matchedQuery = q

        if isSubsequence(q, s), let sc = fuzzyScore(q, s, o, scratch) {
            base = sc
        } else if tokens.count > 1 {
            // "proj src": last token matches the name, earlier tokens match ancestor folders.
            guard let r = tokenScore(e, s, o, scratch) else { return nil }
            base = r
            matchedQuery = UnsafeBufferPointer(start: nil, count: 0)
        } else {
            return nil
        }

        var bonus: Int32 = 0
        let len = s.count
        if matchedQuery.count > 0 {
            // Exact and prefix bonuses ignore leading "_", "-", "." and spaces, so "tmp" ~ "_tmp.avb".
            var lead = 0
            while lead < len && (s[lead] == 95 || s[lead] == 45 || s[lead] == 46 || s[lead] == 32) { lead += 1 }
            let qn = q.count, rest = len - lead
            if rest >= qn && memcmp(s.baseAddress! + lead, q.baseAddress!, qn) == 0 {
                if rest == qn {
                    bonus += 80
                } else {
                    let after = lead + qn
                    bonus += s[after] == 46 && !s[(after + 1)...].contains(46) ? 60 : 25 // "report" ~ "report.pdf"
                }
            }
        }
        if e.flags & EntryFlag.directory != 0 { bonus += 10 } else if e.flags & EntryFlag.package != 0 { bonus += 4 }
        bonus -= min(max(Int32(e.depth) - depthBase, 0) * 2, 24)
        bonus -= Int32(min(max(len - q.count, 0), 48) / 4)
        if !history.isEmpty, let h = history[hashes[i]] { bonus += h }
        return base + bonus
    }

    private func tokenScore(_ e: IndexEntry, _ s: UnsafeBufferPointer<UInt8>, _ o: UnsafeBufferPointer<UInt8>,
                            _ scratch: UnsafeMutablePointer<Int32>) -> Int32? {
        let last = tokens[tokens.count - 1]
        guard let ns = last.withUnsafeBufferPointer({ lb -> Int32? in
            isSubsequence(lb, s) ? fuzzyScore(lb, s, o, scratch) : nil
        }) else { return nil }
        var acc = ns
        var t = tokens.count - 2
        var cur = Int(e.parent)
        while t >= 0 && cur >= 0 {
            let pe = entries[cur]
            let (ps, po) = slices(pe)
            let sc = tokens[t].withUnsafeBufferPointer { tb -> Int32? in
                isSubsequence(tb, ps) ? fuzzyScore(tb, ps, po, scratch) : nil
            }
            if let sc {
                acc += sc / 2
                t -= 1
            }
            cur = Int(pe.parent)
        }
        return t < 0 ? acc - 8 : nil
    }
}

enum NSWorkspaceLite {
    static func isPackage(_ path: String) -> Bool {
        guard (path as NSString).pathExtension.isEmpty == false else { return false }
        return (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }
}

/// Indexes of keyphrase folders that the main index doesn't cover (other volumes, excluded paths).
/// Kept in memory only, rescanned in the background once they're more than 30 seconds old.
private final class ScopeCache {
    private struct Entry { let index: FileIndex; let built: Date }
    private static let maxAge: TimeInterval = 30
    private static let maxItems = 500_000
    private static let maxFolders = 8
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var building: Set<String> = []
    private let queue = DispatchQueue(label: "goto.scope", qos: .userInitiated)

    func index(for dir: String, settings: IndexSettings) -> FileIndex? {
        lock.lock()
        let cached = entries[dir]
        let inProgress = building.contains(dir)
        lock.unlock()
        if let cached {
            if Date().timeIntervalSince(cached.built) > Self.maxAge { prewarm(dir, settings: settings) }
            return cached.index
        }
        if inProgress {
            queue.sync {} // a prewarm scan is running; wait for it rather than scanning twice
            lock.lock()
            defer { lock.unlock() }
            if let ready = entries[dir] { return ready.index }
        }
        return build(dir, settings)
    }

    func prewarm(_ dir: String, settings: IndexSettings) {
        lock.lock()
        let fresh = entries[dir].map { Date().timeIntervalSince($0.built) < Self.maxAge } ?? false
        guard !fresh, building.insert(dir).inserted else { lock.unlock(); return }
        lock.unlock()
        queue.async { self.build(dir, settings) }
    }

    @discardableResult
    private func build(_ dir: String, _ settings: IndexSettings) -> FileIndex? {
        var s = settings
        s.roots = [dir]
        s.maxEntries = Self.maxItems
        let index = IndexBuilder.build(s, progress: nil, isCancelled: { false })
        lock.lock()
        defer { lock.unlock() }
        building.remove(dir)
        guard let index else { return nil }
        entries[dir] = Entry(index: index, built: Date())
        if entries.count > Self.maxFolders, let oldest = entries.min(by: { $0.value.built < $1.value.built })?.key {
            entries.removeValue(forKey: oldest)
        }
        return index
    }
}
