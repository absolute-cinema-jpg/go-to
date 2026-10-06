import AppKit

// MARK: - Window

final class SearchPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .aqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        super.sendEvent(event)
    }
}

// MARK: - Drawing primitives

private final class PanelBackgroundView: NSView {
    var headerHeight: CGFloat = 30
    var footerHeight: CGFloat = 30
    var separatorY: CGFloat?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        Theme.panelBG.withAlphaComponent(Theme.panelOpacity).setFill()
        r.fill()

        // Header strip, like a Resolve panel title bar.
        let header = NSRect(x: 0, y: 0, width: r.width, height: headerHeight)
        NSGradient(starting: Theme.headerTop.withAlphaComponent(0.55), ending: Theme.headerBottom.withAlphaComponent(0.55))?.draw(in: header, angle: 90)
        Theme.etchDark.setFill()
        NSRect(x: 0, y: headerHeight - 1, width: r.width, height: 1).fill()
        NSColor(white: 1, alpha: 0.6).setFill()
        NSRect(x: 0, y: 1, width: r.width, height: 1).fill()

        // Accent marker beside the title.
        Theme.accent.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: NSRect(x: 16, y: headerHeight / 2 - 3, width: 6, height: 6), xRadius: 1.5, yRadius: 1.5).fill()

        if let y = separatorY {
            Theme.etchDark.setFill()
            NSRect(x: 0, y: y, width: r.width, height: 1).fill()
            Theme.etchLight.withAlphaComponent(0.5).setFill()
            NSRect(x: 0, y: y + 1, width: r.width, height: 1).fill()
        }

        let footer = NSRect(x: 0, y: r.height - footerHeight, width: r.width, height: footerHeight)
        Theme.footerBG.withAlphaComponent(0.55).setFill()
        footer.fill()
        Theme.etchDark.setFill()
        NSRect(x: 0, y: footer.minY, width: r.width, height: 1).fill()

        NSGraphicsContext.restoreGraphicsState()
        Theme.borderOuter.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

final class TagView: NSView {
    enum Style { case accent, neutral }
    var text = "" { didSet { needsDisplay = true } }
    var style: Style = .neutral { didSet { needsDisplay = true } }
    var monospaced = false
    override var isFlipped: Bool { true }

    private var attributed: NSAttributedString {
        let color = style == .accent ? Theme.accent.withAlphaComponent(0.85) : Theme.textSecondary
        if monospaced {
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: color,
            ])
        }
        return Theme.caps(text, size: 8.5, color: color, weight: .bold, kern: 1.0)
    }

    var preferredWidth: CGFloat { text.isEmpty ? 0 : ceil(attributed.size().width) + 14 }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if style == .accent {
            Theme.accent.withAlphaComponent(0.06).setFill()
            p.fill()
            Theme.accent.withAlphaComponent(0.3).setStroke()
        } else {
            Theme.keycapBG.setFill()
            p.fill()
            Theme.keycapBorder.setStroke()
        }
        p.lineWidth = 1
        p.stroke()
        let a = attributed
        let size = a.size()
        a.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// A keyphrase "locked in" as a solid token at the start of the search field ("scr ␣" → [scr]).
final class KeyphraseChipView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: isSelected ? Theme.panelBG : Theme.accent,
        ])
    }

    var preferredWidth: CGFloat { text.isEmpty ? 0 : ceil(attributed.size().width) + 22 }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let rect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let p = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isSelected ? Theme.accent : Theme.accent.withAlphaComponent(0.12)).setFill()
        p.fill()
        Theme.accent.withAlphaComponent(isSelected ? 1 : 0.65).setStroke()
        p.lineWidth = 1.5
        p.stroke()
        let a = attributed
        let size = a.size()
        a.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

private final class FooterView: NSView {
    var hints: [(String, String)] = [("↵", "Reveal"), ("⌘↵", "Open"), ("⇥", "Complete"), ("⌘K", "Keyphrase"), ("⌘,", "Settings")]
    var rightText = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 16
        let midY = bounds.midY
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: Theme.textSecondary,
        ]
        for (key, label) in hints {
            let ks = NSAttributedString(string: key, attributes: keyAttrs)
            let kSize = ks.size()
            let cap = NSRect(x: x, y: midY - 8, width: max(18, ceil(kSize.width) + 10), height: 16)
            let p = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            Theme.keycapBG.setFill()
            p.fill()
            Theme.keycapBorder.setStroke()
            p.stroke()
            ks.draw(at: NSPoint(x: cap.midX - kSize.width / 2, y: cap.midY - kSize.height / 2))
            x = cap.maxX + 6
            let ls = Theme.caps(label, size: 8.5, color: Theme.textTertiary, kern: 1.0)
            let lSize = ls.size()
            ls.draw(at: NSPoint(x: x, y: midY - lSize.height / 2))
            x += lSize.width + 16
        }
        if !rightText.isEmpty {
            let rs = Theme.caps(rightText, size: 8.5, color: Theme.textTertiary, kern: 1.0)
            let size = rs.size()
            rs.draw(at: NSPoint(x: bounds.width - 16 - size.width, y: midY - size.height / 2))
        }
    }
}

final class SearchField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 21, weight: .light)
        textColor = Theme.textBright
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        placeholderAttributedString = NSAttributedString(string: "Find a file or folder…", attributes: [
            .font: NSFont.systemFont(ofSize: 21, weight: .light), .foregroundColor: Theme.textTertiary,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Result row

final class ResultRowView: NSView {
    static let height: CGFloat = 46
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let kindTag = TagView()
    private let shortcut = NSTextField(labelWithString: "")
    private var result: SearchResult?
    var onMouseDown: ((Int) -> Void)?
    var isSelected = false { didSet { if oldValue != isSelected { render() } } }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        for l in [title, subtitle, shortcut] {
            l.isBordered = false
            l.drawsBackground = false
            l.isEditable = false
            l.isSelectable = false
            l.cell?.lineBreakMode = .byTruncatingMiddle
            l.cell?.truncatesLastVisibleLine = true
        }
        title.cell?.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = Theme.textSecondary
        shortcut.alignment = .right
        [icon, title, subtitle, kindTag, shortcut].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ r: SearchResult, number: Int) {
        result = r
        icon.image = IconCache.icon(for: r.path)
        let parent = (r.path as NSString).deletingLastPathComponent
        let standardParent = (parent as NSString).standardizingPath
        if let scope = r.scope, standardParent == scope.dir || standardParent.hasPrefix(scope.dir + "/") {
            let inner = String(standardParent.dropFirst(scope.dir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            subtitle.stringValue = inner.isEmpty ? scope.phrase : "\(scope.phrase) › \(inner)"
        } else {
            subtitle.stringValue = parent.isEmpty ? "/" : parent.abbreviatingHome
        }
        if let kp = r.keyphrase {
            kindTag.text = kp
            kindTag.style = .accent
            kindTag.monospaced = true
        } else {
            kindTag.monospaced = false
            kindTag.style = .neutral
            if r.isDirectory {
                kindTag.text = "Folder"
            } else if r.isPackage {
                let ext = (r.name as NSString).pathExtension.lowercased()
                kindTag.text = ext == "app" ? "App" : (ext.isEmpty ? "Package" : ext)
            } else {
                let ext = (r.name as NSString).pathExtension
                kindTag.text = ext.isEmpty || ext.count > 8 ? "File" : ext
            }
        }
        shortcut.attributedStringValue = NSAttributedString(string: number <= 9 ? "⌘\(number)" : "", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: Theme.textTertiary,
        ])
        render()
        needsLayout = true
    }

    private func render() {
        guard let r = result else { return }
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
            .foregroundColor: isSelected ? Theme.textBright : Theme.textPrimary,
        ]
        let s = NSMutableAttributedString(string: r.name, attributes: base)
        for range in nsRanges(r.highlight, in: r.name) {
            s.addAttributes([.foregroundColor: Theme.accent, .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)], range: range)
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        title.attributedStringValue = s
        subtitle.textColor = isSelected ? Theme.textSecondary.blended(withFraction: 0.25, of: .black) : Theme.textSecondary
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        icon.frame = NSRect(x: 20, y: (h - 28) / 2, width: 28, height: 28)
        shortcut.frame = NSRect(x: w - 18 - 26, y: (h - 14) / 2, width: 26, height: 14)
        let tw = kindTag.preferredWidth
        kindTag.frame = NSRect(x: shortcut.frame.minX - 10 - tw, y: (h - 17) / 2, width: tw, height: 17)
        let textX: CGFloat = 60
        let textW = kindTag.frame.minX - 12 - textX
        title.frame = NSRect(x: textX, y: 6, width: textW, height: 19)
        subtitle.frame = NSRect(x: textX, y: 25, width: textW, height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 8, dy: 1)
        let p = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        Theme.rowSelected.setFill()
        p.fill()
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        Theme.accent.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
        NSColor(white: 1, alpha: 0.5).setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event.clickCount) }
}

func nsRanges(_ utf8Offsets: [Int], in s: String) -> [NSRange] {
    let utf8 = s.utf8
    var out: [NSRange] = []
    for off in utf8Offsets where off < utf8.count {
        let i = utf8.index(utf8.startIndex, offsetBy: off)
        guard let si = i.samePosition(in: s.unicodeScalars) else { continue }
        out.append(NSRange(si..<s.unicodeScalars.index(after: si), in: s))
    }
    return out
}

// MARK: - Controller

final class SearchPanelController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let width: CGFloat = 680
    static let headerH: CGFloat = 30
    static let searchH: CGFloat = 60
    static let footerH: CGFloat = 30
    static let listPad: CGFloat = 6
    static let emptyH: CGFloat = 56

    let panel = SearchPanel()
    private let blur = NSVisualEffectView()
    private let background = PanelBackgroundView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    let field = SearchField(frame: .zero)
    private let chipView = KeyphraseChipView()
    private let modeTag = TagView()
    private var rows: [ResultRowView] = []
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footer = FooterView()

    private(set) var results: [SearchResult] = []
    private var resultsQuery: String?
    private var mode: SearchMode = .recent
    private var totalMatches = 0
    private var selected = 0
    private var anchorTop: CGFloat = 0
    private var anchorX: CGFloat = 0
    private var didActivateApp = false
    private var mouseMonitor: Any?

    /// The keyphrase locked into the search field as a token; the text after it searches inside its folder.
    private var chip: Keyphrase?
    /// Whole query (token + text) selected, e.g. on reopening: typing or deleting replaces both.
    private var chipSelected = false { didSet { chipView.isSelected = chipSelected } }

    let engine: SearchEngine
    var contextProvider: () -> SearchContext
    var onActivate: (SearchResult, Bool) -> Void = { _, _ in }
    var onSettings: () -> Void = {}
    var onAddKeyphrase: (SearchResult?) -> Void = { _ in }
    var onWillShow: () -> Void = {}

    init(engine: SearchEngine, contextProvider: @escaping () -> SearchContext) {
        self.engine = engine
        self.contextProvider = contextProvider
        super.init()
        buildViews()
        panel.delegate = self
        panel.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(otherAppActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func buildViews() {
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .aqua)
        blur.maskImage = Self.roundedMask(radius: 11)
        blur.addSubview(background)
        panel.contentView = blur
        titleLabel.attributedStringValue = Theme.caps("Go To", size: 9.5, color: Theme.textSecondary, weight: .bold, kern: 2.0)
        statusLabel.alignment = .right
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .light)
        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        glyph.contentTintColor = Theme.textSecondary
        field.delegate = self
        emptyLabel.alignment = .center
        for _ in 0..<SearchEngine.maxResults {
            let row = ResultRowView(frame: .zero)
            let i = rows.count
            row.onMouseDown = { [weak self] clicks in
                guard let self else { return }
                self.select(i)
                if clicks >= 2 { self.activateSelection(open: false) }
            }
            rows.append(row)
            background.addSubview(row)
        }
        [titleLabel, statusLabel, glyph, chipView, field, modeTag, emptyLabel, footer].forEach(background.addSubview)
        chipView.isHidden = true
        chipView.onClick = { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(self.field)
            self.field.currentEditor()?.selectAll(nil)
            self.chipSelected = true
        }
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                               name: NSTextView.didChangeSelectionNotification, object: nil)
    }

    // MARK: Keyphrase token

    private var chipDir: String? { chip.map { ($0.path.expandingTilde as NSString).standardizingPath } }

    /// What the engine searches for: [scr] + "tmp" → "scr tmp"; [scr] + "/sub" → "scr/sub";
    /// [scr] alone → "scr/" (the folder itself, then its contents).
    private var effectiveQuery: String {
        let text = field.stringValue
        guard let chip else { return text }
        let phrase = chip.phrase.trimmed
        if text.trimmed.isEmpty { return phrase + "/" }
        return text.hasPrefix("/") ? phrase + text : phrase + " " + text
    }

    private func setChip(_ kp: Keyphrase?) {
        chip = kp
        chipSelected = false
        chipView.text = kp?.phrase.trimmed ?? ""
        chipView.isHidden = kp == nil
        let folder = chipDir.map { ($0 as NSString).lastPathComponent }
        field.placeholderAttributedString = NSAttributedString(
            string: folder.map { "Search in \($0)…" } ?? "Find a file or folder…",
            attributes: [.font: NSFont.systemFont(ofSize: 21, weight: .light), .foregroundColor: Theme.textTertiary])
    }

    /// "scr␣" becomes a [scr] token when scr is a keyphrase for a folder.
    private func lockKeyphraseIfTyped() {
        guard chip == nil else { return }
        let text = field.stringValue
        guard let space = text.firstIndex(of: " "), space != text.startIndex else { return }
        let head = text[..<space].lowercased()
        guard let kp = contextProvider().keyphrases.first(where: { $0.normalizedPhrase == head }) else { return }
        var isDir: ObjCBool = false
        let dir = (kp.path.expandingTilde as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return }
        setChip(kp)
        let rest = String(text[text.index(after: space)...])
        field.stringValue = rest
        field.currentEditor()?.selectedRange = NSRange(location: (rest as NSString).length, length: 0)
    }

    @objc private func selectionChanged(_ note: Notification) {
        guard chipSelected, let editor = field.currentEditor() as? NSTextView, note.object as? NSTextView === editor else { return }
        if editor.selectedRange != NSRange(location: 0, length: (field.stringValue as NSString).length) { chipSelected = false }
    }

    /// Stretchable rounded-rect mask so the blur follows the panel's corners.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show(query: String? = nil) {
        onWillShow()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            anchorX = round(vf.midX - Self.width / 2)
            anchorTop = round(vf.maxY - vf.height * 0.2)
        }
        // Every opening starts fresh: no token, no leftover text (or just the query from a goto://show?q= link).
        setChip(nil)
        field.stringValue = query ?? ""
        lockKeyphraseIfTyped()
        apply(engine.searchSync(effectiveQuery, context: contextProvider()))

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if let editor = field.currentEditor() as? NSTextView {
            editor.insertionPointColor = Theme.accent
            editor.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.22),
                                             .foregroundColor: Theme.textBright]
            editor.selectAll(nil)
        }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.hide()
            }
        }
        DispatchQueue.main.async {
            guard self.panel.isVisible, !self.panel.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.field)
            self.didActivateApp = true
        }
    }

    /// `restoreFocus: false` when another app (Finder) is about to come forward: handing focus
    /// back to the previous app happens asynchronously and would land on top of Finder.
    func hide(restoreFocus: Bool = true) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
        if didActivateApp {
            didActivateApp = false
            let otherWindows = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.styleMask.contains(.titled) }
            if restoreFocus && !otherWindows { NSApp.hide(nil) }
        }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    @objc private func otherAppActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier { hide() }
    }

    func setStatus(_ text: String) {
        let s = NSMutableAttributedString(attributedString: Theme.caps(text, size: 8.5, color: Theme.textTertiary, weight: .semibold, kern: 1.0))
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        s.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: s.length))
        statusLabel.attributedStringValue = s
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) {
        lockKeyphraseIfTyped()
        runSearch()
    }

    func runSearch() {
        engine.search(effectiveQuery, context: contextProvider()) { [weak self] out in
            guard let self, out.query == self.effectiveQuery else { return }
            self.apply(out)
        }
    }

    /// Refresh results after the index or keyphrases change, if the panel is open.
    func refreshIfVisible() { if isVisible { runSearch() } }

    private func apply(_ out: SearchOutput) {
        results = out.results
        if let chip, let dir = chipDir {
            // Show locations relative to the token, e.g. "scr › Avid Projects".
            for k in results.indices where results[k].scope == nil {
                results[k].scope = (chip.phrase.trimmed, dir.nfc)
            }
        }
        resultsQuery = out.query
        mode = out.mode
        totalMatches = out.totalMatches
        selected = 0
        for (i, row) in rows.enumerated() {
            if i < results.count {
                row.configure(results[i], number: i + 1)
                row.isSelected = i == selected
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        switch mode {
        case .keyphrase: modeTag.text = "Keyphrase"; modeTag.style = .accent
        case .path: modeTag.text = "Path"; modeTag.style = .neutral
        case .approximate: modeTag.text = "Closest match"; modeTag.style = .neutral
        case .scoped(let phrase): modeTag.text = "In \(phrase)"; modeTag.style = .accent
        default: modeTag.text = ""
        }
        if chip != nil && mode != .approximate {
            modeTag.text = "" // the token itself shows the scope
        }
        switch mode {
        case .recent: footer.rightText = results.isEmpty ? "" : "Recent"
        case .none, .approximate: footer.rightText = ""
        default: footer.rightText = totalMatches == 0 ? "" : (totalMatches == 1 ? "1 match" : "\(Fmt.count(totalMatches)) matches")
        }
        let q = field.stringValue.trimmed
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let message = q.isEmpty ? "" : (chip.map { "No matches for “\(q)” in \($0.phrase.trimmed)" } ?? "No matches for “\(q)”")
        emptyLabel.attributedStringValue = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.textTertiary, .paragraphStyle: centered,
        ])
        layoutPanel()
    }

    private func layoutPanel() {
        let W = Self.width
        let showEmpty = results.isEmpty && !field.stringValue.trimmed.isEmpty
        let listH: CGFloat = !results.isEmpty
            ? Self.listPad * 2 + CGFloat(results.count) * ResultRowView.height
            : (showEmpty ? Self.emptyH : 0)
        let H = Self.headerH + Self.searchH + (listH > 0 ? 1 + listH : 0) + Self.footerH
        panel.setFrame(NSRect(x: anchorX, y: anchorTop - H, width: W, height: H), display: false)
        blur.frame = NSRect(x: 0, y: 0, width: W, height: H)
        background.frame = blur.bounds
        background.headerHeight = Self.headerH
        background.footerHeight = Self.footerH
        background.separatorY = listH > 0 ? Self.headerH + Self.searchH : nil

        titleLabel.frame = NSRect(x: 30, y: (Self.headerH - 13) / 2, width: 120, height: 13)
        statusLabel.frame = NSRect(x: W - 16 - 300, y: (Self.headerH - 13) / 2, width: 300, height: 13)

        let sy = Self.headerH
        glyph.frame = NSRect(x: 20, y: sy + (Self.searchH - 22) / 2, width: 22, height: 22)
        let tagW = modeTag.preferredWidth
        modeTag.isHidden = tagW == 0
        modeTag.frame = NSRect(x: W - 18 - tagW, y: sy + (Self.searchH - 18) / 2, width: tagW, height: 18)
        let fieldRight = tagW > 0 ? modeTag.frame.minX - 12 : W - 18
        var fieldX: CGFloat = 52
        if chip != nil {
            chipView.frame = NSRect(x: 50, y: sy + (Self.searchH - 30) / 2, width: chipView.preferredWidth, height: 30)
            fieldX = chipView.frame.maxX + 8
        }
        field.frame = NSRect(x: fieldX, y: sy + (Self.searchH - 28) / 2, width: fieldRight - fieldX, height: 28)

        let listTop = sy + Self.searchH + 1
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: listTop + Self.listPad + CGFloat(i) * ResultRowView.height,
                               width: W, height: ResultRowView.height)
        }
        emptyLabel.isHidden = !showEmpty
        emptyLabel.frame = NSRect(x: 20, y: listTop + (Self.emptyH - 17) / 2, width: W - 40, height: 17)
        footer.frame = NSRect(x: 0, y: H - Self.footerH, width: W, height: Self.footerH)

        background.needsDisplay = true
        footer.needsDisplay = true
        modeTag.needsDisplay = true
        chipView.needsDisplay = true
        panel.display()
        panel.invalidateShadow()
    }

    // MARK: Keyboard

    private func handleKey(_ e: NSEvent) -> Bool {
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        if chip != nil, let handled = handleChipKey(e, flags: flags) { return handled }
        switch e.keyCode {
        case 36, 76: activateSelection(open: cmd); return true      // return / enter
        case 53: hide(); return true                                 // esc
        case 125: move(1); return true                               // ↓
        case 126: move(-1); return true                              // ↑
        case 48 where !flags.contains(.shift): complete(); return true // tab
        default: break
        }
        if flags.contains(.control), let c = e.charactersIgnoringModifiers {
            if c == "n" || c == "j" { move(1); return true }
            if c == "p" || c == "k" { move(-1); return true }
        }
        guard cmd, let chars = e.charactersIgnoringModifiers?.lowercased() else { return false }
        switch chars {
        case ",": hide(); onSettings(); return true
        case "k": addKeyphrase(); return true
        case "w": hide(); return true
        case "a":
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            chipSelected = chip != nil
            return true
        case "x": NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self); return true
        case "v": NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self); return true
        case "z": NSApp.sendAction(Selector(flags.contains(.shift) ? "redo:" : "undo:"), to: nil, from: self); return true
        case "c":
            if let editor = field.currentEditor(), editor.selectedRange.length > 0 {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            } else if selected < results.count {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(results[selected].path, forType: .string)
            }
            return true
        default:
            if let n = Int(chars), n >= 1, n <= results.count, resultsQuery == effectiveQuery {
                select(n - 1)
                activateSelection(open: false)
                return true
            }
            return false
        }
    }

    /// Delete right after the token removes it as one object; typing over a selected token replaces it.
    /// Returns nil when the key has nothing to do with the token.
    private func handleChipKey(_ e: NSEvent, flags: NSEvent.ModifierFlags) -> Bool? {
        let isDelete = e.keyCode == 51 || e.keyCode == 117
        if chipSelected {
            if isDelete {
                setChip(nil)
                return false // the field then deletes the selected text too
            }
            let typing = !flags.contains(.command) && !flags.contains(.control)
                && (e.characters?.unicodeScalars.first.map { $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) } ?? false)
            if typing {
                setChip(nil)
                return false // the keystroke replaces the selected text
            }
            return nil
        }
        if e.keyCode == 51, let editor = field.currentEditor(), editor.selectedRange == NSRange(location: 0, length: 0) {
            setChip(nil)
            runSearch()
            layoutPanel()
            return true
        }
        return nil
    }

    private func select(_ i: Int) {
        guard !results.isEmpty else { return }
        selected = max(0, min(results.count - 1, i))
        for (k, row) in rows.enumerated() { row.isSelected = k == selected }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        select((selected + delta + results.count) % results.count)
    }

    /// Tab: replace the query with the selected item's path so you can keep drilling down.
    private func complete() {
        guard selected < results.count else { return }
        let r = results[selected]
        var s: String
        if let dir = chipDir, r.path == dir || r.path.hasPrefix(dir + "/") {
            // Inside a token, complete relative to it: [scr] /Avid Projects/
            s = String(r.path.dropFirst(dir.count))
            if r.isDirectory { s += "/" }
            if s.isEmpty { s = "/" }
        } else if let kp = r.keyphrase, r.isDirectory {
            s = kp + "/"
        } else {
            s = r.path.abbreviatingHome
            if r.isDirectory { s += "/" }
        }
        field.stringValue = s
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (s as NSString).length, length: 0)
        }
        chipSelected = false
        apply(engine.searchSync(effectiveQuery, context: contextProvider()))
    }

    private func currentResults() -> [SearchResult] {
        if resultsQuery == effectiveQuery { return results }
        let out = engine.searchSync(effectiveQuery, context: contextProvider())
        apply(out)
        return out.results
    }

    private func activateSelection(open: Bool) {
        let list = currentResults()
        guard selected < list.count else { NSSound.beep(); return }
        let r = list[selected]
        guard FileManager.default.fileExists(atPath: r.path) else {
            NSSound.beep()
            emptyLabel.isHidden = true
            setStatus("Item no longer exists")
            return
        }
        hide(restoreFocus: false)
        onActivate(r, open)
    }

    private func addKeyphrase() {
        if effectiveQuery.trimmed.isEmpty {
            hide()
            onAddKeyphrase(nil) // nothing searched for: just open the keyphrase list
            return
        }
        let list = currentResults()
        guard selected < list.count else { NSSound.beep(); return }
        let r = list[selected]
        hide()
        onAddKeyphrase(r)
    }

    #if GOTO_DEVTOOLS
    // MARK: Snapshot (used by `goto-tools --snapshot` for design review)

    func renderSnapshot(query: String, to url: URL, padding pad: CGFloat = 0) {
        anchorX = 0
        anchorTop = 2000
        setChip(nil)
        field.stringValue = query
        lockKeyphraseIfTyped()
        apply(engine.searchSync(effectiveQuery, context: contextProvider()))
        let view = background
        view.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                                         pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let canvas = NSRect(x: 0, y: 0, width: view.bounds.width + pad * 2, height: view.bounds.height + pad * 2)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = canvas.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        // Stand-in for the desktop (the real blur can't be captured offscreen).
        NSGradient(colors: [Theme.rgb(0x2B5876), Theme.rgb(0x4E4376), Theme.rgb(0xC06C84)])?.draw(in: canvas, angle: -30)
        for k in stride(from: 0, to: canvas.width, by: 90) {
            NSColor(white: 1, alpha: 0.18).setFill()
            NSRect(x: k, y: 0, width: 30, height: canvas.height).fill()
        }
        let panelRect = NSRect(x: pad, y: pad, width: view.bounds.width, height: view.bounds.height)
        let shape = NSBezierPath(roundedRect: panelRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        if pad > 0 {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 28
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor(white: 0.97, alpha: 1).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        shape.addClip()
        NSColor(white: 0.97, alpha: 0.6).setFill()   // approximates the popover blur's lightening
        panelRect.fill()
        rep.draw(in: panelRect)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
}
