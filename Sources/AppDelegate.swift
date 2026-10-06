import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ConfigStore()
    let history = HistoryStore()
    lazy var indexManager = IndexManager(config: store.config)
    let engine = SearchEngine()
    lazy var panel: SearchPanelController = makePanel()
    private var settingsController: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var subscriptions: Set<AnyCancellable> = []

    func makeSearchContext() -> SearchContext {
        SearchContext(index: indexManager.index,
                      keyphrases: store.config.keyphrases,
                      historyBonus: history.bonusTable(),
                      recent: history.recent(limit: SearchEngine.maxResults),
                      includeHidden: store.config.includeHidden,
                      indexSettings: IndexSettings(config: store.config))
    }

    private func makePanel() -> SearchPanelController {
        let p = SearchPanelController(engine: engine) { [unowned self] in self.makeSearchContext() }
        p.onActivate = { [unowned self] result, open in self.activate(result, open: open) }
        p.onSettings = { [unowned self] in self.openSettings() }
        p.onAddKeyphrase = { [unowned self] result in
            if let result { self.store.focusKeyphraseID = self.store.addKeyphrase(path: result.path) }
            self.openSettings(tab: .keyphrases)
        }
        p.onWillShow = { [unowned self] in self.indexManager.panelWillShow() }
        return p
    }

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        indexManager.onIndexChanged = { [unowned self] in
            self.updateStatus()
            self.panel.refreshIfVisible()
        }
        indexManager.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [unowned self] _ in DispatchQueue.main.async { self.updateStatus() } }
            .store(in: &subscriptions)
        store.$config.map(\.indexSignature).removeDuplicates().dropFirst()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [unowned self] _ in self.indexManager.update(config: self.store.config) }
            .store(in: &subscriptions)
        store.$config.map(\.showMenuBarIcon).removeDuplicates()
            .sink { [unowned self] in self.setStatusItemVisible($0) }
            .store(in: &subscriptions)
        store.$config.map(\.keyphrases).removeDuplicates().dropFirst()
            .sink { [unowned self] _ in DispatchQueue.main.async { self.panel.refreshIfVisible() } }
            .store(in: &subscriptions)

        indexManager.start()
        updateStatus()

        if store.isFirstRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.openSettings(tab: .general) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Any app or web page can send these, so they can only show or hide UI, pre-fill a short
    /// query, or request a reindex (rate limited). Nothing here opens or reveals a file.
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, s.count <= 2048,
              let url = URLComponents(string: s), url.scheme?.lowercased() == "goto" else { return }
        let query = url.queryItems?.first { $0.name == "q" }?.value.map(Self.sanitizedQuery)
        switch url.host?.lowercased() ?? "" {
        case "show": panel.show(query: query)
        case "hide": panel.hide()
        case "toggle", "": query != nil ? panel.show(query: query) : panel.toggle()
        case "settings": openSettings()
        case "reindex":
            guard Date().timeIntervalSince(lastURLReindex) > 60 else { return }
            lastURLReindex = Date()
            indexManager.rebuild()
        default: return
        }
    }

    private var lastURLReindex = Date.distantPast

    static func sanitizedQuery(_ q: String) -> String {
        var out = String.UnicodeScalarView()
        var n = 0
        for u in q.unicodeScalars where !CharacterSet.controlCharacters.contains(u) && n < 200 {
            out.append(u)
            n += 1
        }
        return String(out)
    }

    // MARK: Actions

    private func activate(_ result: SearchResult, open: Bool) {
        history.record(result.path)
        DispatchQueue.main.async {
            if open && !result.isDirectory {
                if let risk = LaunchSafety.riskDescription(for: result.path) {
                    switch LaunchSafety.confirm(path: result.path, risk: risk) {
                    case .open: break
                    case .reveal: self.reveal(result.path, enterFolder: false); return
                    case .cancel: NSApp.hide(nil); return // give focus back to the previous app
                    }
                }
                NSWorkspace.shared.open(URL(fileURLWithPath: result.path))
                return
            }
            self.reveal(result.path, enterFolder: open)
        }
    }

    private func reveal(_ path: String, enterFolder: Bool) {
        if let failure = FinderRevealer.reveal(path, enterFolder: enterFolder) {
            FinderRevealer.presentError(failure, path: path)
            return
        }
        // The script already activates Finder; this makes sure it ends up frontmost even if
        // another app was mid-activation, with the window we just used on top.
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?
            .activate(options: [.activateIgnoringOtherApps])
    }

    func openSettings(tab: SettingsTab? = nil) {
        if settingsController == nil {
            settingsController = SettingsWindowController(store: store, index: indexManager) { [unowned self] in
                self.indexManager.rebuild()
            }
        }
        settingsController?.present(tab: tab)
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func rebuildIndex() { indexManager.rebuild() }
    @objc private func openSettingsMenu() { openSettings() }

    private func updateStatus() {
        let m = indexManager
        if m.isBuilding && m.itemCount == 0 {
            panel.setStatus("Indexing · \(Fmt.count(m.progressCount))")
        } else if m.isBuilding {
            panel.setStatus("\(Fmt.count(m.itemCount)) items · refreshing")
        } else {
            panel.setStatus("\(Fmt.count(m.itemCount)) items")
        }
    }

    // MARK: Menus

    private func setStatusItemVisible(_ visible: Bool) {
        if !visible {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "location.magnifyingglass", accessibilityDescription: "Go To")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.addItem(withTitle: "Find in Finder…", action: #selector(togglePanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Rebuild Index", action: #selector(rebuildIndex), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Go To", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Go To", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Go To", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
