import Combine
import Foundation

struct Keyphrase: Codable, Identifiable, Equatable {
    var id = UUID()
    var phrase: String
    var path: String

    enum CodingKeys: String, CodingKey { case phrase, path }

    init(phrase: String, path: String) {
        self.phrase = phrase
        self.path = path
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phrase = try c.decode(String.self, forKey: .phrase)
        path = try c.decode(String.self, forKey: .path)
    }

    var normalizedPhrase: String { phrase.trimmed.lowercased().nfc }
}

struct AppConfig: Codable, Equatable {
    var keyphrases: [Keyphrase] = []
    var searchRoots: [String] = ["~", "/Applications"]
    /// Entries containing "/" exclude one specific folder; bare names exclude every folder with that name.
    var excludes: [String] = ["~/Library", "node_modules", "__pycache__", "DerivedData", "Pods", "venv"]
    var includeHidden = false
    var showMenuBarIcon = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        keyphrases = try c.decodeIfPresent([Keyphrase].self, forKey: .keyphrases) ?? d.keyphrases
        searchRoots = try c.decodeIfPresent([String].self, forKey: .searchRoots) ?? d.searchRoots
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? d.excludes
        includeHidden = try c.decodeIfPresent(Bool.self, forKey: .includeHidden) ?? d.includeHidden
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? d.showMenuBarIcon
    }

    /// Anything that changes what ends up in the file index.
    var indexSignature: String {
        (searchRoots + ["|"] + excludes + [includeHidden ? "hidden" : ""]).joined(separator: "\u{1}")
    }

    func keyphrase(matching phrase: String) -> Keyphrase? {
        let p = phrase.trimmed.lowercased().nfc
        guard !p.isEmpty else { return nil }
        return keyphrases.first { $0.normalizedPhrase == p }
    }
}

enum SettingsTab: String, CaseIterable {
    case keyphrases = "Keyphrases"
    case index = "Index"
    case general = "General"
}

final class ConfigStore: ObservableObject {
    @Published var config: AppConfig
    @Published var focusKeyphraseID: UUID?
    @Published var settingsTab: SettingsTab = .keyphrases
    let isFirstRun: Bool
    private var saveSub: AnyCancellable?

    init() {
        let (cfg, existed) = ConfigStore.load()
        config = cfg
        isFirstRun = !existed
        if !existed { save() }
        saveSub = $config.dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    static func load() -> (AppConfig, Bool) {
        guard let data = try? Data(contentsOf: Paths.configFile) else { return (AppConfig(), false) }
        do {
            return (try JSONDecoder().decode(AppConfig.self, from: data), true)
        } catch {
            NSLog("GoTo: could not parse config.json (\(error)); using defaults")
            return (AppConfig(), true)
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(config) {
            try? data.write(to: Paths.configFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.configFile.path)
        }
    }

    @discardableResult
    func addKeyphrase(path: String, phrase: String? = nil) -> UUID {
        let display = path.abbreviatingHome
        let kp = Keyphrase(phrase: phrase ?? suggestPhrase(for: display), path: display)
        config.keyphrases.append(kp)
        return kp.id
    }

    /// Initials of the item's name ("phil's project" -> "pp"), made unique.
    func suggestPhrase(for path: String) -> String {
        var name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty { name = (name as NSString).deletingPathExtension }
        let words = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0 != "s" }
        var base: String
        if words.count >= 2 {
            base = String(words.prefix(4).compactMap { $0.first })
        } else {
            base = String((words.first ?? "kp").prefix(3))
        }
        if base.isEmpty { base = "kp" }
        let taken = Set(config.keyphrases.map(\.normalizedPhrase))
        var candidate = base
        var n = 2
        while taken.contains(candidate) { candidate = base + "\(n)"; n += 1 }
        return candidate
    }
}

// MARK: - History (frecency)

struct HistoryItem: Codable {
    var count: Int
    var last: Date
}

final class HistoryStore {
    private(set) var items: [String: HistoryItem] = [:]
    private var cachedBonus: [UInt64: Int32]?
    /// Until the saved history is loaded, saving would overwrite it with a partial copy.
    private var loaded = false
    private var recordedBeforeLoad = false

    /// Loads the encrypted history in the background (reading the key may show a keychain prompt).
    init() {
        DispatchQueue.global(qos: .userInitiated).async {
            let saved = Self.load()
            DispatchQueue.main.async { self.merge(saved) }
        }
    }

    private static func load() -> [String: HistoryItem] {
        let decoder = JSONDecoder()
        if let data = SecureStore.read(from: Paths.historyFile),
           let items = try? decoder.decode([String: HistoryItem].self, from: data) {
            return items
        }
        // Migrate the plaintext history written by version 1.0, then remove it.
        let legacy = Paths.legacyHistoryFile
        guard let data = try? Data(contentsOf: legacy) else { return [:] }
        let items = (try? decoder.decode([String: HistoryItem].self, from: data)) ?? [:]
        if let enc = try? JSONEncoder().encode(items), SecureStore.write(enc, to: Paths.historyFile) {
            try? FileManager.default.removeItem(at: legacy)
        }
        return items
    }

    private func merge(_ saved: [String: HistoryItem]) {
        for (path, item) in saved {
            if let mine = items[path] {
                items[path] = HistoryItem(count: mine.count + item.count, last: max(mine.last, item.last))
            } else {
                items[path] = item
            }
        }
        cachedBonus = nil
        loaded = true
        if recordedBeforeLoad { save() }
    }

    func record(_ path: String) {
        let p = path.nfc
        var item = items[p] ?? HistoryItem(count: 0, last: Date())
        item.count += 1
        item.last = Date()
        items[p] = item
        if items.count > 600 {
            let now = Date()
            let keep = items.sorted { Self.bonus($0.value, now) > Self.bonus($1.value, now) }.prefix(500)
            items = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        cachedBonus = nil
        if loaded { save() } else { recordedBeforeLoad = true }
    }

    private func save() {
        let snapshot = items
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                SecureStore.write(data, to: Paths.historyFile)
            }
        }
    }

    static func bonus(_ item: HistoryItem, _ now: Date) -> Int32 {
        let days = now.timeIntervalSince(item.last) / 86400
        let recency: Int32 = days < 1 ? 30 : days < 7 ? 18 : days < 30 ? 8 : 0
        return Int32(min(item.count, 10)) * 5 + recency
    }

    func bonusTable() -> [UInt64: Int32] {
        if let cachedBonus { return cachedBonus }
        let now = Date()
        var table: [UInt64: Int32] = [:]
        for (path, item) in items { table[pathHash(path)] = Self.bonus(item, now) }
        cachedBonus = table
        return table
    }

    func recent(limit: Int) -> [String] {
        let now = Date()
        return items.sorted {
            $0.value.last == $1.value.last ? Self.bonus($0.value, now) > Self.bonus($1.value, now) : $0.value.last > $1.value.last
        }
        .prefix(limit * 2)
        .map(\.key)
    }
}
