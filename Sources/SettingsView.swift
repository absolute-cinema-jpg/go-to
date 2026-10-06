import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: ConfigStore

    init(store: ConfigStore, index: IndexManager, onRebuild: @escaping () -> Void) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Go To Settings"
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = Theme.panelBG
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsView(store: store, index: index, onRebuild: onRebuild))
        window.setContentSize(NSSize(width: 780, height: 560))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(tab: SettingsTab? = nil) {
        if let tab { store.settingsTab = tab }
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        store.save()
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var index: IndexManager
    let onRebuild: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.gtEtchDark).frame(height: 1)
            Group {
                switch store.settingsTab {
                case .keyphrases: KeyphrasesPane(store: store)
                case .index: IndexPane(store: store, index: index, onRebuild: onRebuild)
                case .general: GeneralPane(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.gtPanel)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Spacer().frame(width: 84)
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                TabButton(tab: tab, selected: $store.settingsTab)
            }
            Spacer()
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.gtAccent).frame(width: 7, height: 7)
                Text("GO TO").font(.system(size: 9.5, weight: .bold)).tracking(2).foregroundColor(.gtText2)
            }
            .padding(.bottom, 14)
            .padding(.trailing, 18)
        }
        .frame(height: 46)
        .background(LinearGradient(colors: [Color(nsColor: Theme.headerTop), Color(nsColor: Theme.headerBottom)],
                                   startPoint: .top, endPoint: .bottom))
    }
}

private struct TabButton: View {
    let tab: SettingsTab
    @Binding var selected: SettingsTab
    @State private var hover = false

    var icon: String {
        switch tab {
        case .keyphrases: return "character.cursor.ibeam"
        case .index: return "internaldrive"
        case .general: return "slider.horizontal.3"
        }
    }

    var body: some View {
        let isSel = selected == tab
        Button { selected = tab } label: {
            VStack(spacing: 9) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 10.5, weight: .medium))
                    Text(tab.rawValue.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.3)
                }
                .foregroundColor(isSel ? .gtAccent : (hover ? .gtText : .gtText2))
                Rectangle().fill(isSel ? Color.gtAccent : Color.clear).frame(height: 2)
            }
            .padding(.horizontal, 10)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Shared components

struct GTButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        GTButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct GTButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 10, weight: .bold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundColor(prominent ? Color.white : (hover ? .gtText : Color.gtText2))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(prominent
                              ? Color.gtAccent.opacity(pressed ? 0.75 : (hover ? 1 : 0.92))
                              : Color(white: pressed ? 0.88 : (hover ? 0.96 : 1.0)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(prominent ? Color.white.opacity(0.15) : Color.gtBorder, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hover = $0 }
        }
    }
}

struct GTIconButton: View {
    let systemName: String
    var danger = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(hover ? (danger ? .gtDanger : .gtText) : .gtText3)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Color.gtAccent.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct GTToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Color.gtAccent : Color(white: 0.82))
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
                    .frame(width: 32, height: 18)
                Circle().fill(Color.white.opacity(0.95)).frame(width: 14, height: 14).padding(2)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

/// A Resolve-style inspector section: caps title strip over a recessed body.
struct GTSection<Content: View, Accessory: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(1.4).foregroundColor(.gtText2)
                Spacer()
                accessory
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color.gtHeader)
            Rectangle().fill(Color.gtEtchDark).frame(height: 1)
            content
        }
        .background(Color.gtCard)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gtBorder, lineWidth: 1))
    }
}

extension GTSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

struct GTTextFieldModifier: ViewModifier {
    var invalid = false
    var focused = false
    var monospaced = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12.5, weight: .medium, design: .monospaced) : .system(size: 12.5))
            .foregroundColor(.gtText)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.gtField))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(invalid ? Color.gtDanger : (focused ? Color.gtAccent.opacity(0.8) : Color.gtBorder), lineWidth: 1))
    }
}

private func choosePath(startingAt path: String?, foldersOnly: Bool = false) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = !foldersOnly
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.prompt = "Choose"
    if let path, !path.isEmpty {
        let full = path.expandingTilde
        panel.directoryURL = URL(fileURLWithPath: (full as NSString).deletingLastPathComponent)
    }
    return panel.runModal() == .OK ? panel.url?.path.abbreviatingHome : nil
}

// MARK: - Keyphrases

private struct KeyphrasesPane: View {
    @ObservedObject var store: ConfigStore
    @FocusState private var focused: UUID?
    @State private var dropTargeted = false

    private var duplicates: Set<String> {
        var seen = Set<String>(), dup = Set<String>()
        for kp in store.config.keyphrases where !kp.normalizedPhrase.isEmpty {
            if !seen.insert(kp.normalizedPhrase).inserted { dup.insert(kp.normalizedPhrase) }
        }
        return dup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Keyphrases").font(.system(size: 17, weight: .semibold)).foregroundColor(.gtText)
                Text("Type a keyphrase exactly and press ↵ to jump straight to its target. Add a space and more text to search inside it (“pph tmp”), or “/” to browse it.")
                    .font(.system(size: 11.5)).foregroundColor(.gtText2)
            }

            GTSection("Shortcuts", accessory: {
                Text("\(store.config.keyphrases.count) DEFINED").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundColor(.gtText3)
            }) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("KEYPHRASE").frame(width: 150, alignment: .leading)
                        Text("TARGET")
                        Spacer()
                    }
                    .font(.system(size: 8.5, weight: .bold)).tracking(1.2).foregroundColor(.gtText3)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)

                    if store.config.keyphrases.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .light)).foregroundColor(.gtText3)
                            Text("No keyphrases yet").font(.system(size: 12.5, weight: .medium)).foregroundColor(.gtText2)
                            Text("Click Add, or drop files and folders here.").font(.system(size: 11)).foregroundColor(.gtText3)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                // Rows get values plus id-based bindings, never bindings into the array:
                                // an index-based binding crashes if its row is deleted while being edited.
                                ForEach(store.config.keyphrases) { kp in
                                    KeyphraseRow(kp: kp, store: store,
                                                 isDuplicate: duplicates.contains(kp.normalizedPhrase),
                                                 focused: $focused,
                                                 onDelete: { delete(kp.id) })
                                }
                            }
                            .padding(.horizontal, 14).padding(.bottom, 12)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.gtAccent.opacity(dropTargeted ? 0.8 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .padding(6))
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async {
                            let id = store.addKeyphrase(path: url.path)
                            focused = id
                        }
                    }
                }
                return true
            }

            HStack {
                Button {
                    if let path = choosePath(startingAt: nil) {
                        focused = store.addKeyphrase(path: path)
                    }
                } label: { Label("Add Keyphrase", systemImage: "plus") }
                    .buttonStyle(GTButtonStyle(prominent: true))
                Spacer()
                if !duplicates.isEmpty {
                    Text("Duplicate keyphrases — only the first one is used.").font(.system(size: 11)).foregroundColor(.gtDanger)
                }
            }
        }
        .padding(20)
        .onAppear(perform: consumePendingFocus)
        .onChange(of: store.focusKeyphraseID) { _ in consumePendingFocus() }
    }

    private func delete(_ id: UUID) {
        focused = nil // end editing first so the field can't write back into a removed row
        DispatchQueue.main.async { store.config.keyphrases.removeAll { $0.id == id } }
    }

    private func consumePendingFocus() {
        guard let id = store.focusKeyphraseID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focused = id
            store.focusKeyphraseID = nil
        }
    }
}

private struct KeyphraseRow: View {
    let kp: Keyphrase
    @ObservedObject var store: ConfigStore
    let isDuplicate: Bool
    var focused: FocusState<UUID?>.Binding
    let onDelete: () -> Void

    private var phrase: Binding<String> {
        let id = kp.id
        return Binding(get: { store.config.keyphrases.first { $0.id == id }?.phrase ?? "" },
                       set: { value in store.updateKeyphrase(id) { $0.phrase = value } })
    }

    var body: some View {
        let full = kp.path.expandingTilde
        let exists = FileManager.default.fileExists(atPath: full)
        HStack(spacing: 10) {
            TextField("phrase", text: phrase)
                .focused(focused, equals: kp.id)
                .modifier(GTTextFieldModifier(invalid: isDuplicate || kp.phrase.trimmed.isEmpty,
                                              focused: focused.wrappedValue == kp.id, monospaced: true))
                .frame(width: 130)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundColor(.gtText3)
            HStack(spacing: 8) {
                Image(nsImage: IconCache.icon(for: full)).resizable().frame(width: 16, height: 16)
                Text(kp.path.isEmpty ? "Choose a target…" : kp.path)
                    .font(.system(size: 12))
                    .foregroundColor(exists ? .gtText : .gtDanger)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if !exists && !kp.path.isEmpty {
                    Text("MISSING").font(.system(size: 8.5, weight: .bold)).tracking(1).foregroundColor(.gtDanger)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.gtPanel))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { choose() }
            .help(full)
            Button("Choose…", action: choose).buttonStyle(GTButtonStyle())
            GTIconButton(systemName: "xmark", danger: true, action: onDelete).help("Remove keyphrase")
        }
    }

    private func choose() {
        if let p = choosePath(startingAt: kp.path) { store.updateKeyphrase(kp.id) { $0.path = p } }
    }
}

// MARK: - Index

private struct IndexPane: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var index: IndexManager
    let onRebuild: () -> Void
    @State private var newExclude = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                HStack(alignment: .top, spacing: 16) {
                    GTSection("Search locations", accessory: {
                        GTIconButton(systemName: "plus") {
                            if let p = choosePath(startingAt: nil, foldersOnly: true), !store.config.searchRoots.contains(p) {
                                store.config.searchRoots.append(p)
                            }
                        }.help("Add a folder to index")
                    }) {
                        listRows(store.config.searchRoots, icon: true) { item in store.config.searchRoots.removeAll { $0 == item } }
                    }
                    GTSection("Excluded") {
                        VStack(spacing: 0) {
                            listRows(store.config.excludes, icon: false) { item in store.config.excludes.removeAll { $0 == item } }
                            HStack(spacing: 8) {
                                TextField("Folder name or ~/path", text: $newExclude, onCommit: addExclude)
                                    .modifier(GTTextFieldModifier())
                                Button("Add", action: addExclude).buttonStyle(GTButtonStyle())
                                    .disabled(newExclude.trimmed.isEmpty)
                            }
                            .padding(10)
                        }
                    }
                }
                GTSection("Options") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $store.config.includeHidden) {
                            Text("Include hidden files and folders").font(.system(size: 12.5)).foregroundColor(.gtText)
                        }
                        .toggleStyle(GTToggleStyle())
                        Text("Names (e.g. node_modules) skip every folder with that name; paths (~/Library) skip one folder. Packages like .app bundles are indexed as single items.")
                            .font(.system(size: 11)).foregroundColor(.gtText3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                }
            }
            .padding(20)
        }
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.count(index.isBuilding && index.itemCount == 0 ? index.progressCount : index.itemCount))
                    .font(.system(size: 30, weight: .light)).monospacedDigit().foregroundColor(.gtText)
                Text("ITEMS INDEXED").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundColor(.gtText3)
            }
            Rectangle().fill(Color.gtBorder).frame(width: 1, height: 40)
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if index.isBuilding {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).scaleEffect(0.8)
                            Text("Scanning… \(Fmt.count(index.progressCount)) items").foregroundColor(.gtAccent)
                        }
                    } else if let built = index.lastBuilt {
                        Text("Updated \(Fmt.relative(built))").foregroundColor(.gtText)
                    } else {
                        Text("Not indexed yet").foregroundColor(.gtText2)
                    }
                    if index.lastDuration > 0 {
                        Text("Last scan took \(Fmt.duration(index.lastDuration)) · updates automatically as files change")
                            .foregroundColor(.gtText3)
                    }
                }
                .font(.system(size: 11.5))
            }
            Spacer()
            Button(action: onRebuild) { Label("Rebuild Now", systemImage: "arrow.clockwise") }
                .buttonStyle(GTButtonStyle())
                .disabled(index.isBuilding)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gtCard))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gtBorder, lineWidth: 1))
    }

    private func listRows(_ items: [String], icon: Bool, remove: @escaping (String) -> Void) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 8) {
                    if icon {
                        Image(nsImage: IconCache.icon(for: item.expandingTilde)).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: item.contains("/") ? "folder" : "textformat")
                            .font(.system(size: 10)).foregroundColor(.gtText3).frame(width: 16)
                    }
                    Text(item).font(.system(size: 12, design: item.contains("/") ? .default : .monospaced))
                        .foregroundColor(.gtText).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    GTIconButton(systemName: "xmark", danger: true) { remove(item) }
                }
                .padding(.leading, 12).padding(.trailing, 6)
                .frame(height: 32)
                .background(i % 2 == 1 ? Color.black.opacity(0.025) : .clear)
            }
        }
        .padding(.vertical, 4)
    }

    private func addExclude() {
        let t = newExclude.trimmed
        guard !t.isEmpty else { return }
        if !store.config.excludes.contains(t) { store.config.excludes.append(t) }
        newExclude = ""
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var store: ConfigStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var copied = false
    static let command = "open -g goto://toggle"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GTSection("Hotkey") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bind any key in Karabiner-Elements to this shell command:")
                            .font(.system(size: 12)).foregroundColor(.gtText2)
                        HStack(spacing: 8) {
                            Text(Self.command)
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                .foregroundColor(.gtAccent)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.gtField))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.gtBorder, lineWidth: 1))
                            Button(copied ? "Copied" : "Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Self.command, forType: .string)
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                            }
                            .buttonStyle(GTButtonStyle(prominent: true))
                        }
                        Text("Also available: goto://show, goto://show?q=text, goto://settings, goto://reindex")
                            .font(.system(size: 11)).foregroundColor(.gtText3)
                    }
                    .padding(14)
                }

                GTSection("Behaviour") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $store.config.showMenuBarIcon) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show menu bar icon").font(.system(size: 12.5)).foregroundColor(.gtText)
                                Text("When hidden, open Settings with ⌘, from the search panel.")
                                    .font(.system(size: 11)).foregroundColor(.gtText3)
                            }
                        }
                        .toggleStyle(GTToggleStyle())
                        Rectangle().fill(Color.gtEtchDark).frame(height: 1)
                        Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch at login").font(.system(size: 12.5)).foregroundColor(.gtText)
                                if let loginError {
                                    Text(loginError).font(.system(size: 11)).foregroundColor(.gtDanger)
                                }
                            }
                        }
                        .toggleStyle(GTToggleStyle())
                    }
                    .padding(14)
                }

                GTSection("Keys in the search panel") {
                    VStack(alignment: .leading, spacing: 7) {
                        keyRow("↵", "Reveal and select in Finder")
                        keyRow("⌘↵", "Open — enter the folder, or open the file")
                        keyRow("⇥", "Complete path to drill into a folder")
                        keyRow("↑ ↓", "Move selection   (also ⌃N / ⌃P)")
                        keyRow("⌘1–8", "Reveal the numbered result")
                        keyRow("⌘K", "Add a keyphrase for the selected result")
                        keyRow("⌘C", "Copy the selected path")
                        keyRow("esc", "Close")
                    }
                    .padding(14)
                }

                GTSection("Configuration") {
                    HStack {
                        Text(Paths.configFile.path.abbreviatingHome)
                            .font(.system(size: 12, design: .monospaced)).foregroundColor(.gtText2)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Reveal in Finder") {
                            store.save()
                            FinderRevealer.reveal(Paths.configFile.path)
                        }
                        .buttonStyle(GTButtonStyle())
                    }
                    .padding(14)
                }
            }
            .padding(20)
        }
    }

    private func keyRow(_ key: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(key).font(.system(size: 10.5, weight: .medium)).foregroundColor(.gtText2)
                .padding(.horizontal, 7).frame(minWidth: 44, minHeight: 20)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.gtKeycap))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: Theme.keycapBorder), lineWidth: 1))
            Text(text).font(.system(size: 12)).foregroundColor(.gtText)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
