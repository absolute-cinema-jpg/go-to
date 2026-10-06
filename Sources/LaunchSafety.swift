import AppKit
import UniformTypeIdentifiers

/// ⌘↵ hands files to NSWorkspace.open, which runs apps, scripts and installers. A file named to
/// win the ranking could end up as the top result, so anything that executes needs a confirmation.
enum LaunchSafety {
    private static let riskyExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "pl", "rb", "php", "js",
        "scpt", "scptd", "applescript", "workflow", "action", "pkg", "mpkg", "terminal", "jar",
        "inetloc", "webloc", "fileloc", "url", "osax", "prefpane", "kext", "mobileconfig", "saver",
        "qlgenerator", "plugin", "bundle", "service", "shortcut", "dylib", "so",
    ]
    private static let riskyTypes: [UTType] = [.executable, .application, .script, .shellScript, .appleScript, .unixExecutable]
    /// Apps here are installed system-wide and can only be written with admin rights.
    private static let trustedAppDirs = ["/Applications/", "/System/Applications/", "/System/Library/CoreServices/"]

    /// A short description of why opening `path` needs confirmation, or nil if it's an ordinary document.
    static func riskDescription(for path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .quarantinePropertiesKey])
        let type = values?.contentType
        let isApp = ext == "app" || type?.conforms(to: .application) == true
        if isApp && trustedAppDirs.contains(where: { path.hasPrefix($0) }) && values?.quarantineProperties == nil {
            return nil
        }
        if isApp { return "an application" }
        if riskyExtensions.contains(ext) || riskyTypes.contains(where: { type?.conforms(to: $0) == true }) {
            return "a script, installer or other file that can run code"
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
           FileManager.default.isExecutableFile(atPath: path) {
            return "an executable file"
        }
        return nil
    }

    enum Decision { case open, reveal, cancel }

    static func confirm(path: String, risk: String) -> Decision {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open “\((path as NSString).lastPathComponent)”?"
        let quarantined = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil
        alert.informativeText = "This is \(risk)\(quarantined ? " downloaded from the internet" : "")."
            + "\n\n\(path.abbreviatingHome)"
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .reveal
        case .alertSecondButtonReturn: return .open
        default: return .cancel
        }
    }
}
