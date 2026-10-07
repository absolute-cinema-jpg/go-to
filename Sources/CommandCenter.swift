import AppKit

/// Runs command keywords and keeps track of the ones running in the background: while any are,
/// a stop button sits in the menu bar. A notice appears only if one fails.
final class CommandCenter: NSObject {
    private struct Running {
        let id: UUID
        let name: String
        let process: Process
        var stopping = false
    }

    private var running: [Running] = []
    private var stopItem: NSStatusItem?
    private let toast = ToastController()

    func run(_ cmd: ShellCommand, args: String) {
        let name = cmd.phrase.trimmed.isEmpty ? "Command" : cmd.phrase.trimmed
        if cmd.runInTerminal {
            do {
                try CommandRunner.runInTerminal(cmd, args: args)
            } catch {
                toast.show("Couldn’t open Terminal for \(name)", detail: error.localizedDescription, style: .failure, duration: 6)
            }
            return
        }
        let id = UUID()
        let process = CommandRunner.runInBackground(cmd, args: args) { [weak self] outcome in
            self?.finished(id, name: name, outcome: outcome)
        }
        guard let process else { return } // couldn't start; the completion already reported it
        running.append(Running(id: id, name: name, process: process))
        updateStopItem()
    }

    private func finished(_ id: UUID, name: String, outcome: CommandRunner.Outcome) {
        let stopped = running.first { $0.id == id }?.stopping ?? false
        running.removeAll { $0.id == id }
        updateStopItem()
        if !stopped && !outcome.succeeded {
            toast.show("\(name) failed (exit \(outcome.status))", detail: outcome.lastLine, style: .failure,
                       output: outcome.output, duration: 8)
        }
    }

    private func stop(_ id: UUID) {
        guard let i = running.firstIndex(where: { $0.id == id }), !running[i].stopping else { return }
        running[i].stopping = true
        CommandRunner.terminateTree(running[i].process.processIdentifier)
    }

    @objc private func stopSingle() { running.first.map { stop($0.id) } }
    @objc private func stopAll() { running.map(\.id).forEach(stop) }
    @objc private func stopFromMenu(_ item: NSMenuItem) {
        if let id = item.representedObject as? UUID { stop(id) }
    }

    /// One command: clicking the icon stops it. Several: the icon opens a menu to stop one or all.
    private func updateStopItem() {
        guard !running.isEmpty else {
            if let item = stopItem { NSStatusBar.system.removeStatusItem(item) }
            stopItem = nil
            return
        }
        let item = stopItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        stopItem = item
        let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop command")
        image?.isTemplate = true
        item.button?.image = image
        if running.count == 1 {
            item.menu = nil
            item.button?.target = self
            item.button?.action = #selector(stopSingle)
            item.button?.toolTip = "Stop \(running[0].name)"
        } else {
            let menu = NSMenu()
            for r in running {
                let mi = NSMenuItem(title: r.stopping ? "Stopping \(r.name)…" : "Stop \(r.name)",
                                    action: #selector(stopFromMenu(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = r.id
                mi.isEnabled = !r.stopping
                menu.addItem(mi)
            }
            menu.addItem(.separator())
            let all = NSMenuItem(title: "Stop All", action: #selector(stopAll), keyEquivalent: "")
            all.target = self
            menu.addItem(all)
            item.menu = menu
            item.button?.toolTip = "\(running.count) commands running"
        }
    }
}
