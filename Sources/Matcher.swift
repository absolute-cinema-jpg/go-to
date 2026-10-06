import Foundation

// Fuzzy matching in the spirit of fzf: every query byte must appear in order, and
// matches are rewarded for landing on word boundaries and for running consecutively.
// Everything works on ASCII-lowercased UTF-8 bytes for speed.

let matchNeg: Int32 = -1_000_000

enum Score {
    static let match: Int32 = 16
    static let boundaryStart: Int32 = 12
    static let boundarySep: Int32 = 10
    static let camel: Int32 = 8
    static let digit: Int32 = 3
    static let consecutive: Int32 = 8
    static let gapOpen: Int32 = 4
    static let gapExtend: Int32 = 1
    static let leadingMax = 12
}

/// space _ - . / ( ) [ ] , ' & +
@inline(__always) func isSeparator(_ c: UInt8) -> Bool {
    switch c {
    case 32, 95, 45, 46, 47, 40, 41, 91, 93, 44, 39, 38, 43: return true
    default: return false
    }
}

/// A space in the query matches any separator in the name ("my proj" ~ "my_project").
@inline(__always) func bytesMatch(_ q: UInt8, _ s: UInt8) -> Bool { q == s || (q == 32 && isSeparator(s)) }

@inline(__always) func isSubsequence(_ q: UnsafeBufferPointer<UInt8>, _ s: UnsafeBufferPointer<UInt8>) -> Bool {
    let qn = q.count
    if qn == 0 { return true }
    if qn > s.count { return false }
    var qi = 0
    var qc = q[0]
    for c in s where bytesMatch(qc, c) {
        qi += 1
        if qi == qn { return true }
        qc = q[qi]
    }
    return false
}

@inline(__always) func positionBonus(_ lower: UnsafeBufferPointer<UInt8>, _ orig: UnsafeBufferPointer<UInt8>, _ j: Int) -> Int32 {
    if j == 0 { return Score.boundaryStart }
    if isSeparator(lower[j - 1]) { return Score.boundarySep }
    let oc = orig[j], op = orig[j - 1]
    if (oc &- 65) < 26 && (op &- 97) < 26 { return Score.camel }
    if (oc &- 48) < 10 && (op &- 48) >= 10 { return Score.digit }
    return 0
}

/// Best alignment score of `q` inside `s`, or nil if `q` is not a subsequence.
/// `scratch` must hold at least `4 * s.count` values.
func fuzzyScore(_ q: UnsafeBufferPointer<UInt8>, _ s: UnsafeBufferPointer<UInt8>,
                _ orig: UnsafeBufferPointer<UInt8>, _ scratch: UnsafeMutablePointer<Int32>) -> Int32? {
    let m = q.count, n = s.count
    if m == 0 { return 0 }
    if m > n { return nil }
    var M = scratch, H = scratch + n, M2 = scratch + 2 * n, H2 = scratch + 3 * n

    var run = matchNeg
    let q0 = q[0]
    for j in 0..<n {
        var v = matchNeg
        if bytesMatch(q0, s[j]) {
            v = Score.match + positionBonus(s, orig, j) - Int32(min(j, Score.leadingMax))
        }
        M[j] = v
        run = max(v, run > matchNeg ? run - Score.gapExtend : matchNeg)
        H[j] = run
    }
    if m > 1 {
        for i in 1..<m {
            let qc = q[i]
            run = matchNeg
            for j in 0..<n {
                var v = matchNeg
                if j >= i && bytesMatch(qc, s[j]) {
                    var p = matchNeg
                    let d = M[j - 1]
                    if d > matchNeg { p = d + Score.consecutive }
                    if j >= 2 {
                        let g = H[j - 2]
                        if g > matchNeg { p = max(p, g - Score.gapOpen) }
                    }
                    if p > matchNeg { v = p + Score.match + positionBonus(s, orig, j) }
                }
                M2[j] = v
                run = max(v, run > matchNeg ? run - Score.gapExtend : matchNeg)
                H2[j] = run
            }
            swap(&M, &M2)
            swap(&H, &H2)
        }
    }
    var best = matchNeg
    for j in (m - 1)..<n where M[j] > best { best = M[j] }
    return best > matchNeg ? best : nil
}

/// Same alignment as `fuzzyScore`, but returns the matched UTF-8 byte offsets for highlighting.
func fuzzyPositions(_ q: [UInt8], in name: String) -> [Int] {
    let orig = Array(name.utf8)
    let low = asciiLower(orig)
    let m = q.count, n = low.count
    guard m > 0, m <= n else { return [] }
    return low.withUnsafeBufferPointer { s in
        orig.withUnsafeBufferPointer { o in
            q.withUnsafeBufferPointer { qb -> [Int] in
                guard isSubsequence(qb, s) else { return [] }
                var M = [Int32](repeating: matchNeg, count: m * n)
                var H = [Int32](repeating: matchNeg, count: m * n)
                var diag = [Bool](repeating: false, count: m * n)
                for i in 0..<m {
                    var run = matchNeg
                    for j in 0..<n {
                        var v = matchNeg
                        if j >= i && bytesMatch(qb[i], s[j]) {
                            if i == 0 {
                                v = Score.match + positionBonus(s, o, j) - Int32(min(j, Score.leadingMax))
                            } else {
                                var p = matchNeg
                                var fromDiag = false
                                let d = M[(i - 1) * n + j - 1]
                                if d > matchNeg { p = d + Score.consecutive; fromDiag = true }
                                if j >= 2 {
                                    let g = H[(i - 1) * n + j - 2]
                                    if g > matchNeg && g - Score.gapOpen > p { p = g - Score.gapOpen; fromDiag = false }
                                }
                                if p > matchNeg {
                                    v = p + Score.match + positionBonus(s, o, j)
                                    diag[i * n + j] = fromDiag
                                }
                            }
                        }
                        M[i * n + j] = v
                        run = max(v, run > matchNeg ? run - Score.gapExtend : matchNeg)
                        H[i * n + j] = run
                    }
                }
                var bestJ = -1
                var best = matchNeg
                for j in 0..<n where M[(m - 1) * n + j] > best { best = M[(m - 1) * n + j]; bestJ = j }
                guard bestJ >= 0 else { return [] }
                var positions: [Int] = []
                var j = bestJ
                var i = m - 1
                while true {
                    positions.append(j)
                    if i == 0 { break }
                    if diag[i * n + j] {
                        j -= 1
                    } else {
                        var bk = -1
                        var bv = matchNeg
                        if j >= 2 {
                            for k in 0...(j - 2) {
                                let v = M[(i - 1) * n + k]
                                if v > matchNeg {
                                    let adj = v - Int32(j - 2 - k) * Score.gapExtend
                                    if adj > bv { bv = adj; bk = k }
                                }
                            }
                        }
                        guard bk >= 0 else { break }
                        j = bk
                    }
                    i -= 1
                }
                return positions.reversed()
            }
        }
    }
}

/// Optimal-string-alignment edit distance (Levenshtein + adjacent transpositions).
/// Returns `maxDist + 1` as soon as the distance is known to exceed `maxDist`.
/// `buf` must hold `3 * (b.count + 1)` values.
func editDistance(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>,
                  maxDist: Int, _ buf: UnsafeMutablePointer<Int>) -> Int {
    let n = a.count, m = b.count
    if abs(n - m) > maxDist { return maxDist + 1 }
    if n == 0 || m == 0 { return max(n, m) }
    var prev2 = buf, prev = buf + (m + 1), cur = buf + 2 * (m + 1)
    for j in 0...m { prev[j] = j; prev2[j] = j }
    for i in 1...n {
        cur[0] = i
        var rowMin = i
        for j in 1...m {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                v = min(v, prev2[j - 2] + 1)
            }
            cur[j] = v
            rowMin = min(rowMin, v)
        }
        if rowMin > maxDist { return maxDist + 1 }
        let t = prev2
        prev2 = prev
        prev = cur
        cur = t
    }
    return prev[m]
}
