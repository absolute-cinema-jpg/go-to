import AppKit

/// A small notice near the top of the screen for background command results, in the dark
/// terminal palette that marks everything to do with commands.
/// Click it to copy the command's full output.
final class ToastController {
    private let panel: NSPanel
    private let view = ToastView()
    private var hideWork: DispatchWorkItem?
    private var fullOutput = ""

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        view.onClick = { [weak self] in
            guard let self else { return }
            if !self.fullOutput.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.fullOutput, forType: .string)
            }
            self.hide()
        }
    }

    enum Style { case running, success, failure }

    func show(_ title: String, detail: String, style: Style, output: String = "", duration: TimeInterval? = nil) {
        fullOutput = output
        view.title = title
        view.detail = detail
        view.style = style
        view.canCopy = !output.isEmpty
        let width = min(max(view.preferredWidth, 260), 520)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrame(NSRect(x: round(vf.midX - width / 2), y: vf.maxY - 56 - 14, width: width, height: 56), display: true)
        }
        view.needsDisplay = true
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        hideWork?.cancel()
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }
}

private final class ToastView: NSView {
    var title = ""
    var detail = ""
    var style: ToastController.Style = .running
    var canCopy = false
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }

    private var titleString: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.Term.text,
        ])
    }

    private var detailString: NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let text = detail + (canCopy ? (detail.isEmpty ? "" : "  ·  ") + "click to copy output" : "")
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: Theme.Term.text2, .paragraphStyle: para,
        ])
    }

    var preferredWidth: CGFloat { max(titleString.size().width, detailString.size().width) + 56 }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        Theme.Term.bg.setFill()
        shape.fill()
        Theme.Term.border.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let dot = NSRect(x: 16, y: 16, width: 8, height: 8)
        switch style {
        case .running: Theme.Term.text3.setFill()
        case .success: Theme.Term.prompt.setFill()
        case .failure: Theme.danger.setFill()
        }
        NSBezierPath(ovalIn: dot).fill()

        titleString.draw(at: NSPoint(x: 34, y: 10))
        detailString.draw(in: NSRect(x: 34, y: 30, width: bounds.width - 48, height: 16))
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
