import AppKit

/// AeroSpace (a tiling window manager) runs its own workspaces and parks the windows of hidden
/// ones off screen, so activating Finder doesn't always switch to the workspace holding the
/// window we just used. When AeroSpace is running, we ask it to focus that window directly.
enum AeroSpace {
    private static let bundleID = "bobko.aerospace"
    private static let cliPaths = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]

    private static var cli: String? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        return cliPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Focuses Finder's window titled `title`, switching AeroSpace workspace if needed. If several
    /// share the title, the one highest in the window stack wins. Blocks briefly; call off the main thread.
    static func focusFinderWindow(titled title: String, finderPID: pid_t) {
        guard let cli else { return }
        for attempt in 0..<3 {
            // The window title can lag a moment behind Finder changing folders.
            if attempt > 0 { usleep(120_000) }
            guard let windows = finderWindows(cli) else { return }
            let matching = Set(windows.filter { $0.title == title }.map(\.id))
            guard !matching.isEmpty else { continue }
            let id = stackOrder(of: finderPID).first(where: matching.contains) ?? matching.first!
            _ = run(cli, ["focus", "--window-id", String(id)])
            return
        }
    }

    private struct Window: Decodable {
        let id: Int
        let title: String
        enum CodingKeys: String, CodingKey { case id = "window-id", title = "window-title" }
    }

    private static func finderWindows(_ cli: String) -> [Window]? {
        guard let out = run(cli, ["list-windows", "--monitor", "all", "--app-bundle-id", "com.apple.finder",
                                  "--json", "--format", "%{window-id} %{window-title}"]) else { return nil }
        return try? JSONDecoder().decode([Window].self, from: out)
    }

    /// Finder's window numbers, front to back (AeroSpace window ids are the same numbers).
    private static func stackOrder(of pid: pid_t) -> [Int] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return w[kCGWindowNumber as String] as? Int
        }
    }

    /// Runs the CLI with fixed arguments (no shell) and a short timeout; returns stdout on success.
    private static func run(_ cli: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        var out = Data()
        let reader = DispatchQueue.global(qos: .userInitiated)
        let readDone = DispatchSemaphore(value: 0)
        reader.async { out = pipe.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + 2) == .timedOut { p.terminate(); return nil }
        _ = readDone.wait(timeout: .now() + 1)
        return p.terminationStatus == 0 ? out : nil
    }
}
