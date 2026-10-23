import AppKit
import ApplicationServices

/// Open and save dialogs. When the app you were in has one in front, Go To sends the dialog to
/// the chosen item instead of revealing it in Finder, through the dialog's own Go to Folder
/// sheet (⌘⇧G). This needs Accessibility permission; without it Go To always uses Finder.
enum FileDialog {
    enum Kind { case open, save }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Adds Go To to the Accessibility list (macOS asks first) and opens that settings pane.
    static func requestAccess() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard !AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The open or save dialog in front of `pid`'s windows, as a standalone panel or as a sheet.
    static func frontDialog(of pid: pid_t) -> Kind? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        if let kind = kind(of: window) { return kind }
        for child in elements(window, kAXChildrenAttribute) where string(child, kAXRoleAttribute) == "AXSheet" {
            if let kind = kind(of: child) { return kind }
        }
        return nil
    }

    private static func kind(of e: AXUIElement) -> Kind? {
        switch string(e, kAXIdentifierAttribute) {
        case "open-panel": return .open
        case "save-panel": return .save
        default: return nil
        }
    }

    /// Brings `app` forward and sends its dialog to `path`: a folder is entered; a file is selected
    /// in an open dialog, or its folder entered in a save dialog (keeping the name already typed).
    /// Steps run on the main queue, waiting on each other; `done` reports whether all of them ran.
    static func navigate(app: NSRunningApplication, kind: Kind, to path: String, isDirectory: Bool,
                         done: @escaping (Bool) -> Void) {
        let target = kind == .save && !isDirectory ? (path as NSString).deletingLastPathComponent : path
        let pid = app.processIdentifier
        app.activate(options: [.activateIgnoringOtherApps])
        // Wait for the app to be in front and for keys still held from pressing ↵ (e.g. ⌘) to be released.
        poll(timeout: 1.5, until: {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                && CGEventSource.flagsState(.combinedSessionState).intersection(modifierMask).isEmpty
        }) { ready in
            guard ready, frontDialog(of: pid) == kind else { return done(false) }
            let before = focusedElement()
            press(5, flags: [.maskCommand, .maskShift]) // ⌘⇧G: Go to Folder
            // The Go to Folder field takes focus once its sheet is up.
            poll(timeout: 1.5, until: {
                guard let now = focusedElement(), before.map({ !CFEqual($0, now) }) ?? true else { return false }
                return ["AXTextField", "AXComboBox", "AXTextArea"].contains(string(now, kAXRoleAttribute) ?? "")
            }) { opened in
                guard opened else { return done(false) }
                press(0, flags: .maskCommand) // ⌘A: replace whatever the field holds
                // No trailing slash: with one, the field's suggestions would put ↵ on the first item inside.
                typeText(target.hasSuffix("/") && target.count > 1 ? String(target.dropLast()) : target)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    press(36, flags: []) // ↵
                    done(true)
                }
            }
        }
    }

    // MARK: Accessibility helpers

    private static let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        return element(system, kAXFocusedUIElementAttribute)
    }

    private static func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func element(_ e: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(e, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func elements(_ e: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let list = value(e, name) as? [AnyObject] else { return [] }
        return list.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    private static func string(_ e: AXUIElement, _ name: String) -> String? { value(e, name) as? String }

    // MARK: Keystrokes

    /// A private source, so the keys we send don't pick up modifiers from the real keyboard.
    private static let source = CGEventSource(stateID: .privateState)

    private static func press(_ key: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    /// Types `text` as Unicode, independent of the keyboard layout.
    private static func typeText(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cghidEventTap)
            }
            i += 20
        }
    }

    private static func poll(timeout: TimeInterval, until condition: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if condition() { return then(true) }
            guard Date() < deadline else { return then(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: check)
        }
        check()
    }
}
