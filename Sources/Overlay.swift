import AppKit

struct Tint: Equatable {
    let rect: CGRect
    let color: ChatColor
}

private final class TintView: NSView {
    var tints: [Tint] = [] {
        didSet { if tints != oldValue { needsDisplay = true } }
    }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        for tint in tints where tint.rect.intersects(dirtyRect) {
            tint.color.draw(in: tint.rect)
        }
    }
}

final class Overlay {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
    private let view = TintView(frame: .zero)

    init() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
    }

    var isVisible: Bool { panel.isVisible }
    var paintedRows: Int { isVisible ? view.tints.count : 0 }

    func hide() { panel.orderOut(nil) }

    func render(rows: [ChatRow], in viewport: CGRect?, colors: Assignments) {
        let tints = rows.compactMap { row in colors.color(for: row.id).map { Tint(rect: row.rect, color: $0) } }
        guard !tints.isEmpty, let viewport, let top = NSScreen.screens.first?.frame.maxY else { hide(); return }
        // Keep the overlay window anchored to the scrolling viewport. Newly
        // visible rows can change the drawing without moving the window itself.
        let bounds = viewport.integral
        let window = CGRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
        view.tints = tints.map { Tint(rect: $0.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY), color: $0.color) }
        if panel.frame != window { panel.setFrame(window, display: true) }
        view.displayIfNeeded()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
