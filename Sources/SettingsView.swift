import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: ConfigStore

    init(store: ConfigStore, index: IndexManager, onRebuild: @escaping () -> Void,
         onRunCommand: @escaping (ShellCommand) -> Void) {
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
        window.minSize = NSSize(width: 680, height: 420)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: SettingsView(store: store, index: index, onRebuild: onRebuild,
                                                                 onRunCommand: onRunCommand))
        // By default the window resizes itself to the content's ideal size, which can run off the
        // bottom of the screen. Keep the size the user (or we) chose; panes scroll instead.
        if #available(macOS 13, *) { hosting.sizingOptions = [] }
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 780, height: 560))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func present(tab: SettingsTab? = nil) {
        if let tab { store.settingsTab = tab }
        fitOnScreen()
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shrink and move the window so all of it is visible on its screen.
    private func fitOnScreen() {
        guard let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width - 20)
        frame.size.height = min(frame.height, visible.height - 20)
        frame.origin.x = min(max(frame.minX, visible.minX + 10), visible.maxX - 10 - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY + 10), visible.maxY - 10 - frame.height)
        if frame != window.frame { window.setFrame(frame, display: true) }
    }

    /// One field editor for the window's text fields, so the cursor can match the tab: the default
    /// black cursor disappears on the dark Commands tab.
    private let fieldEditor: NSTextView = {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        return editor
    }()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        let dark = store.settingsTab == .commands
        fieldEditor.insertionPointColor = dark ? Theme.Term.prompt : Theme.accent
        fieldEditor.selectedTextAttributes = [.backgroundColor: (dark ? Theme.Term.prompt : Theme.accent).withAlphaComponent(0.25)]
        return fieldEditor
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
    let onRunCommand: (ShellCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.gtEtchDark).frame(height: 1)
            Group {
                switch store.settingsTab {
                case .keyphrases: KeyphrasesPane(store: store)
                case .commands: CommandsPane(store: store, onRun: onRunCommand)
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
        case .commands: return "terminal"
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
    /// Terminal palette, for the Commands tab.
    var dark = false
    func makeBody(configuration: Configuration) -> some View {
        if dark {
            DarkButtonBody(configuration: configuration, prominent: prominent)
        } else {
            GTButtonBody(configuration: configuration, prominent: prominent)
        }
    }

    private struct DarkButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: 10, weight: .bold))
                .gtTracking(0.9)
                .textCase(.uppercase)
                .foregroundColor(prominent ? Color.termBG : (hover ? .termText : .termText2))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(prominent
                              ? Color.termPrompt.opacity(pressed ? 0.7 : (hover ? 1 : 0.9))
                              : Color.white.opacity(pressed ? 0.02 : (hover ? 0.08 : 0.04)))
                )
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(prominent ? Color.clear : Color.termBorder, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { hover = $0 }
        }
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
                .gtTracking(0.9)
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
    var dark = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(hover ? (danger ? .gtDanger : (dark ? .termPrompt : .gtText)) : (dark ? .termText3 : .gtText3))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(hover ? (dark ? Color.white.opacity(0.07) : Color.gtAccent.opacity(0.1)) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct GTToggleStyle: ToggleStyle {
    var dark = false
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? (dark ? Color.termPrompt : Color.gtAccent) : (dark ? Color(white: 0.24) : Color(white: 0.82)))
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
    var dark = false
    func body(content: Content) -> some View {
        let focusColor = dark ? Color.termPrompt.opacity(0.7) : Color.gtAccent.opacity(0.8)
        return content
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12.5, weight: .medium, design: .monospaced) : .system(size: 12.5))
            .foregroundColor(dark ? .termText : .gtText)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(dark ? Color.termField : Color.gtField))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(invalid ? Color.gtDanger : (focused ? focusColor : (dark ? Color.termBorder : Color.gtBorder)),
                              lineWidth: 1))
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

    private var duplicates: Set<String> { store.config.duplicatePhrases }

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
                    .font(.system(size: 8.5, weight: .bold)).gtTracking(1.2).foregroundColor(.gtText3)
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
                    Text("Duplicate keywords — keyphrases win over commands, otherwise the first is used.").font(.system(size: 11)).foregroundColor(.gtDanger)
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

    @FocusState private var editingPath: Bool

    private var phrase: Binding<String> {
        let id = kp.id
        return Binding(get: { store.config.keyphrases.first { $0.id == id }?.phrase ?? "" },
                       set: { value in store.updateKeyphrase(id) { $0.phrase = value } })
    }

    private var path: Binding<String> {
        let id = kp.id
        return Binding(get: { store.config.keyphrases.first { $0.id == id }?.path ?? "" },
                       set: { value in store.updateKeyphrase(id) { $0.path = value } })
    }

    /// Tidy a typed or pasted path: trim whitespace and any trailing "/".
    private func normalizePath() {
        var p = kp.path.trimmed
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if p != kp.path { store.updateKeyphrase(kp.id) { $0.path = p } }
    }

    var body: some View {
        let full = kp.path.expandingTilde
        HStack(spacing: 10) {
            TextField("phrase", text: phrase)
                .focused(focused, equals: kp.id)
                .modifier(GTTextFieldModifier(invalid: isDuplicate || kp.phrase.trimmed.isEmpty,
                                              focused: focused.wrappedValue == kp.id, monospaced: true))
                .frame(width: 130)
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundColor(.gtText3)
            HStack(spacing: 8) {
                // Exists check runs on the trimmed text so a pasted trailing space doesn't flag it.
                let typed = kp.path.trimmed.expandingTilde
                let found = !typed.isEmpty && FileManager.default.fileExists(atPath: typed)
                Image(nsImage: found ? IconCache.icon(for: typed) : NSWorkspace.shared.icon(for: .folder))
                    .resizable().frame(width: 16, height: 16)
                    .opacity(found ? 1 : 0.4)
                TextField("~/path/to/folder", text: path)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(found || kp.path.trimmed.isEmpty ? .gtText : .gtDanger)
                    .focused($editingPath)
                    .onSubmit(normalizePath)
                    .onChange(of: editingPath) { editing in if !editing { normalizePath() } }
                if !found && !kp.path.trimmed.isEmpty {
                    Text("MISSING").font(.system(size: 8.5, weight: .bold)).tracking(1).foregroundColor(.gtDanger)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.gtPanel))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(editingPath ? Color.gtAccent.opacity(0.8) : Color.clear, lineWidth: 1))
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
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var copied = false
    static let command = "open -g goto://toggle"

    private var commandRow: some View {
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
            .buttonStyle(GTButtonStyle())
            .frame(width: 76)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GTSection("Opening Go To") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Run this shell command from a keyboard shortcut to open Go To:")
                            .font(.system(size: 12)).foregroundColor(.gtText2).fixedSize(horizontal: false, vertical: true)
                        commandRow
                        Text("macOS Shortcuts, Keyboard Maestro, Raycast, BetterTouchTool and similar apps can all run it from a hotkey.")
                            .font(.system(size: 11)).foregroundColor(.gtText3).fixedSize(horizontal: false, vertical: true)
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
                        if LoginItem.isSupported {
                            Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Launch at login").font(.system(size: 12.5)).foregroundColor(.gtText)
                                    if let loginError {
                                        Text(loginError).font(.system(size: 11)).foregroundColor(.gtDanger)
                                    }
                                }
                            }
                            .toggleStyle(GTToggleStyle())
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch at login").font(.system(size: 12.5)).foregroundColor(.gtText)
                                Text("On macOS 12, add Go To under System Preferences › Users & Groups › Login Items.")
                                    .font(.system(size: 11)).foregroundColor(.gtText3)
                            }
                        }
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
            try LoginItem.set(on)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = LoginItem.isEnabled
    }
}

/// Launch at login via SMAppService, which needs macOS 13; on 12 the setting is hidden.
private enum LoginItem {
    static var isSupported: Bool {
        if #available(macOS 13, *) { return true }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func set(_ on: Bool) throws {
        guard #available(macOS 13, *) else { return }
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

extension View {
    /// Letter-spacing on any view needs macOS 13; on 12 the text is simply set without it.
    @ViewBuilder func gtTracking(_ value: CGFloat) -> some View {
        if #available(macOS 13, *) { tracking(value) } else { self }
    }
}

// MARK: - Commands

/// Commands use the dark terminal palette, set against the light theme of the other tabs.
private struct CommandsPane: View {
    @ObservedObject var store: ConfigStore
    let onRun: (ShellCommand) -> Void
    @FocusState private var focused: UUID?
    @FocusState private var draftFocus: DraftField?
    @State private var draftPhrase = ""
    @State private var draftCommand = ""
    @State private var draftTerminal = false
    @State private var draftCommandFocusRequest = 0

    private enum DraftField { case phrase }

    private var draftIsDuplicate: Bool {
        let p = draftPhrase.trimmed.lowercased().nfc
        return !p.isEmpty && (store.config.keyphrases.map(\.normalizedPhrase) + store.config.commands.map(\.normalizedPhrase)).contains(p)
    }
    private var canAddDraft: Bool { !draftPhrase.trimmed.isEmpty && !draftCommand.trimmed.isEmpty && !draftIsDuplicate }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("$").font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundColor(.termPrompt)
                    Text("Commands").font(.system(size: 17, weight: .semibold)).foregroundColor(.termText)
                }
                Text("Type a keyword and press ↵ in the search panel to run its command. Type the keyword and a space to add arguments: they arrive as $1, $2… (\"$@\"), with the whole text in $GOTO_QUERY.")
                    .font(.system(size: 11.5)).foregroundColor(.termText2).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("SHELL COMMANDS").font(.system(size: 9.5, weight: .bold)).tracking(1.4).foregroundColor(.termText2)
                    Spacer()
                    Text("\(store.config.commands.count) DEFINED").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundColor(.termText3)
                }
                .padding(.horizontal, 14).frame(height: 32)
                .background(Color.white.opacity(0.03))
                Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1)

                HStack(spacing: 10) {
                    Text("KEYWORD").frame(width: 112, alignment: .leading)
                    Text("COMMAND")
                    Spacer()
                    Text("TERMINAL").frame(width: 56)
                    Spacer().frame(width: 62)
                }
                .font(.system(size: 8.5, weight: .bold)).gtTracking(1.2).foregroundColor(.termText3)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)

                // Always-ready row: type a keyword, Tab, a command, ↵.
                HStack(alignment: .top, spacing: 10) {
                    TextField("new keyword", text: $draftPhrase)
                        .focused($draftFocus, equals: .phrase)
                        .onSubmit { draftCommandFocusRequest += 1 }
                        .modifier(GTTextFieldModifier(invalid: draftIsDuplicate, focused: draftFocus == .phrase, monospaced: true, dark: true))
                        .frame(width: 112)
                    CommandEditor(text: $draftCommand, placeholder: "command to run — ↵ adds, ⇧↵ new line",
                                  focusRequest: $draftCommandFocusRequest, onSubmit: addDraft)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(isOn: $draftTerminal) { EmptyView() }
                        .toggleStyle(GTToggleStyle(dark: true))
                        .frame(width: 56)
                    Button("Add", action: addDraft)
                        .buttonStyle(GTButtonStyle(prominent: true, dark: true))
                        .disabled(!canAddDraft)
                        .frame(width: 62)
                }
                .padding(.horizontal, 14).padding(.bottom, 10)

                Rectangle().fill(Color.termBorder).frame(height: 1).padding(.horizontal, 14)

                if store.config.commands.isEmpty {
                    VStack(spacing: 6) {
                        Text("No commands yet").font(.system(size: 12.5, weight: .medium)).foregroundColor(.termText2)
                        Text("e.g. keyword “flush”, command “dscacheutil -flushcache”").font(.system(size: 11, design: .monospaced)).foregroundColor(.termText3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            // Value rows with id-based bindings (see KeyphrasesPane for why).
                            ForEach(store.config.commands) { cmd in
                                CommandRow(cmd: cmd, store: store,
                                           isDuplicate: store.config.duplicatePhrases.contains(cmd.normalizedPhrase),
                                           focused: $focused,
                                           onRun: { onRun(cmd) },
                                           onDelete: { delete(cmd.id) })
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.termCard)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.termBorder, lineWidth: 1))

            HStack(spacing: 6) {
                if draftIsDuplicate || !store.config.duplicatePhrases.isEmpty {
                    Text("Keyword already used — keyphrases win over commands.").foregroundColor(.gtDanger)
                }
                Spacer()
                Text("Runs as you, in zsh, from your home folder, with Go To’s access to your files.").foregroundColor(.termText3)
            }
            .font(.system(size: 11))
        }
        .padding(20)
        .background(Color.termBG)
        .onAppear { if store.config.commands.isEmpty { draftFocus = .phrase } }
    }

    private func addDraft() {
        guard canAddDraft else { return }
        store.config.commands.append(ShellCommand(phrase: draftPhrase.trimmed, command: draftCommand.trimmed,
                                                  runInTerminal: draftTerminal))
        draftPhrase = ""
        draftCommand = ""
        draftTerminal = false
        draftFocus = .phrase
    }

    private func delete(_ id: UUID) {
        focused = nil
        DispatchQueue.main.async { store.config.commands.removeAll { $0.id == id } }
    }
}

private struct CommandRow: View {
    let cmd: ShellCommand
    @ObservedObject var store: ConfigStore
    let isDuplicate: Bool
    var focused: FocusState<UUID?>.Binding
    let onRun: () -> Void
    let onDelete: () -> Void
    private func binding<T>(_ key: WritableKeyPath<ShellCommand, T>, default value: T) -> Binding<T> {
        let id = cmd.id
        return Binding(get: { store.config.commands.first { $0.id == id }?[keyPath: key] ?? value },
                       set: { new in store.updateCommand(id) { $0[keyPath: key] = new } })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TextField("keyword", text: binding(\.phrase, default: ""))
                .focused(focused, equals: cmd.id)
                .modifier(GTTextFieldModifier(invalid: isDuplicate || cmd.phrase.trimmed.isEmpty,
                                              focused: focused.wrappedValue == cmd.id, monospaced: true, dark: true))
                .frame(width: 112)
            CommandEditor(text: binding(\.command, default: ""), placeholder: "command to run",
                          invalid: cmd.command.trimmed.isEmpty, focusRequest: .constant(0), onSubmit: {})
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: binding(\.runInTerminal, default: false)) { EmptyView() }
                .toggleStyle(GTToggleStyle(dark: true))
                .frame(width: 56)
                .help("On: opens a Terminal window. Off: runs in the background and shows a notice when done.")
            HStack(spacing: 4) {
                GTIconButton(systemName: "play.fill", dark: true, action: onRun)
                    .help("Run now, without arguments")
                    .disabled(cmd.command.trimmed.isEmpty)
                GTIconButton(systemName: "xmark", danger: true, dark: true, action: onDelete).help("Remove command")
            }
            .frame(width: 62)
        }
    }
}

// MARK: - Multi-line command editor

/// A dark, monospaced text box for shell commands: long lines wrap, the box grows with each line,
/// ↵ submits and ⇧↵ / ⌥↵ insert a line break. Smart quotes and dashes are off, since turning
/// ' into ’ would quietly break a command.
struct CommandEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var invalid = false
    /// Increment to move keyboard focus into the editor.
    @Binding var focusRequest: Int
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> GrowingTextView {
        let view = GrowingTextView()
        view.delegate = context.coordinator
        view.onSubmit = { context.coordinator.parent.onSubmit() }
        view.string = text
        view.placeholder = placeholder
        return view
    }

    func updateNSView(_ view: GrowingTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text {
            view.string = text
            view.invalidateIntrinsicContentSize()
        }
        view.placeholder = placeholder
        view.invalid = invalid
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommandEditor
        var lastFocusRequest: Int
        init(_ parent: CommandEditor) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

final class GrowingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var invalid = false { didSet { if invalid != oldValue { needsDisplay = true } } }
    private var focused = false { didSet { needsDisplay = true } }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        textColor = Theme.Term.text
        insertionPointColor = Theme.Term.prompt
        selectedTextAttributes = [.backgroundColor: Theme.Term.prompt.withAlphaComponent(0.28), .foregroundColor: Theme.Term.text]
        drawsBackground = false
        textContainerInset = NSSize(width: 5, height: 6)
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 3
        isVerticallyResizable = false
        isHorizontallyResizable = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    override var intrinsicContentSize: NSSize {
        guard let layout = layoutManager, let container = textContainer else { return super.intrinsicContentSize }
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height + textContainerInset.height * 2)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(height, 28))
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() } // re-wrap at the new width
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focused = true }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { focused = false }
        return ok
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                window?.makeFirstResponder(nil) // finish editing first, so onSubmit can move focus elsewhere
                onSubmit?()
            }
        case #selector(insertTab(_:)):
            window?.selectNextKeyView(nil)
        case #selector(insertBacktab(_:)):
            window?.selectPreviousKeyView(nil)
        default:
            super.doCommand(by: selector)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        Theme.Term.field.setFill()
        box.fill()
        let border = invalid ? Theme.danger : (focused ? Theme.Term.prompt.withAlphaComponent(0.7) : Theme.Term.border)
        border.setStroke()
        box.lineWidth = 1
        box.stroke()
        super.draw(dirtyRect)
        if string.isEmpty && !placeholder.isEmpty {
            NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: Theme.Term.text3,
            ]).draw(at: NSPoint(x: textContainerInset.width + 3, y: textContainerInset.height))
        }
    }
}
