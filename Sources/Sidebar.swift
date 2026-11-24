import AppKit
import ApplicationServices

struct ChatRow: Equatable {
    let id: UUID
    let title: String
    let rect: CGRect // macOS Accessibility coordinates with a top-left origin
}

struct SidebarSnapshot {
    var rows: [ChatRow] = []
    var unmatched = 0
    var viewport: CGRect?

    init(viewport: CGRect? = nil) { self.viewport = viewport }
    var foundSidebar: Bool { viewport != nil }
}

struct SidebarRowReference {
    let element: AXUIElement
    let title: String
    let id: UUID?
}

struct SidebarTracker {
    let window: AXUIElement
    let scrollArea: AXUIElement
    let references: [SidebarRowReference]
}

enum CodexSidebar {
    static let bundleID = "com.openai.codex"

    // Keep offscreen rows in document order so the next visible rows are
    // available without a tree walk at every scroll position.
    static func track(pid: pid_t, inventory: Inventory, allowMainWindow: Bool = false) -> SidebarTracker? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let focused: AXUIElement? = attribute(app, kAXFocusedWindowAttribute)
        let main: AXUIElement? = allowMainWindow ? attribute(app, kAXMainWindowAttribute) : nil
        guard let window = focused ?? main,
              let windowFrame = frame(window),
              let sidebar = navigation(in: window, windowFrame: windowFrame),
              let scrollArea = scrollArea(in: sidebar) else { return nil }

        var references: [SidebarRowReference] = []
        var pending = [scrollArea]
        var budget = 7_000
        let deadline = ProcessInfo.processInfo.systemUptime + 0.65
        while let element = pending.popLast() {
            guard budget > 0, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            budget -= 1
            let role: String? = attribute(element, kAXRoleAttribute)
            if role == "AXButton" || role == "AXLink" {
                let classes: [String] = attribute(element, "AXDOMClassList") ?? []
                guard classes.contains(where: { $0.contains("app-action-sidebar-thread-selected") }),
                      let title: String = attribute(element, kAXTitleAttribute) else { continue }
                references.append(SidebarRowReference(element: element, title: title, id: inventory.identify(title: title)))
                continue
            }
            if role == "AXMenu" || role == "AXDialog" { continue }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            pending.append(contentsOf: children.reversed())
        }
        return SidebarTracker(window: window, scrollArea: scrollArea, references: references)
    }

    static func scan(pid: pid_t, inventory: Inventory, allowMainWindow: Bool = false) -> SidebarSnapshot {
        guard let tracking = track(pid: pid, inventory: inventory, allowMainWindow: allowMainWindow) else { return SidebarSnapshot() }
        return currentFrame(of: tracking) ?? SidebarSnapshot()
    }

    // The renderer clamps offscreen rectangles to the scroll edges.
    // Use their y position rather than scanning hundreds of hidden rows.
    static func firstCandidate(_ count: Int, top: CGFloat, frameAt: (Int) -> CGRect?) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = (lower + upper) / 2
            guard let rect = frameAt(middle) else { return 0 }
            if rect.maxY <= top + 2.5 {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    static func currentFrame(of tracker: SidebarTracker) -> SidebarSnapshot? {
        guard let viewport = frame(tracker.scrollArea), let window = frame(tracker.window) else { return nil }
        let clip = viewport.intersection(window)
        guard clip.width >= 100, clip.height >= 70 else { return SidebarSnapshot() }

        let references = tracker.references
        let start = firstCandidate(references.count, top: clip.minY) { index in frame(references[index].element) }
        var snapshot = SidebarSnapshot(viewport: clip)
        for index in max(0, start - 1)..<references.count {
            let reference = references[index]
            guard let (bounds, title) = rowGeometry(reference.element) else { continue }
            if bounds.minY >= clip.maxY - 0.75 { break }
            let visible = bounds.intersection(clip)
            guard !visible.isNull, visible.width >= clip.width * 0.46, visible.height > 2.5,
                  title == reference.title else { continue }
            if let id = reference.id {
                snapshot.rows.append(ChatRow(id: id, title: reference.title, rect: visible))
            } else {
                snapshot.unmatched += 1
            }
        }
        return snapshot
    }

    private static func scrollArea(in sidebar: AXUIElement) -> AXUIElement? {
        var pending = [sidebar]
        var budget = 48
        while !pending.isEmpty, budget > 0 {
            budget -= 1
            let element = pending.removeFirst()
            let classes: [String] = attribute(element, "AXDOMClassList") ?? []
            if classes.contains("overflow-y-auto") || classes.contains("overflow-y-scroll") {
                return element
            }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            pending.append(contentsOf: children)
        }
        return nil
    }

    private static func navigation(in window: AXUIElement, windowFrame: CGRect) -> AXUIElement? {
        var pending: [(AXUIElement, Bool)] = [(window, false)]
        var budget = 180
        while let (element, insideSidebarLandmark) = pending.popLast(), budget > 0 {
            budget -= 1
            if let bounds = frame(element),
               bounds.minX > windowFrame.minX + min(240, windowFrame.width * 0.36) || bounds.height < 28 {
                continue
            }
            let subrole: String? = attribute(element, kAXSubroleAttribute)
            if insideSidebarLandmark && subrole == "AXLandmarkNavigation" {
                // The narrow tab rail is also a navigation landmark.
                if let bounds = frame(element), bounds.width >= 100 { return element }
                continue
            }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            let inside = insideSidebarLandmark || subrole == "AXLandmarkComplementary"
            pending.append(contentsOf: children.reversed().map { ($0, inside) })
        }
        return nil
    }

    private static let geometryAttributes = ["AXFrame", kAXTitleAttribute] as CFArray

    private static func rowGeometry(_ element: AXUIElement) -> (CGRect, String)? {
        var result: CFArray?
        if AXUIElementCopyMultipleAttributeValues(element, geometryAttributes, [], &result) == .success,
           let values = result as? [CFTypeRef], values.count == 2, let title = values[1] as? String,
           CFGetTypeID(values[0]) == AXValueGetTypeID() {
            let value = unsafeBitCast(values[0], to: AXValue.self)
            var rect = CGRect.zero
            if AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect) { return (rect, title) }
        }
        guard let rect = frame(element), let title: String = attribute(element, kAXTitleAttribute) else { return nil }
        return (rect, title)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        if let value: AXValue = attribute(element, "AXFrame"), AXValueGetType(value) == .cgRect {
            var rect = CGRect.zero
            if AXValueGetValue(value, .cgRect, &rect) { return rect }
        }
        guard let point: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(point, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
