import AppKit
import ApplicationServices
import QuartzCore

private struct SidebarUpdate {
    var tracking: SidebarTracker?
    var colors = Assignments()
    var error: String?
}

private final class SidebarReader {
    private var cachedVersion: FileVersion?
    private var inventory: Inventory?
    private var folders = FolderCatalog()
    private var foldersReadAt = -Double.infinity
    private let store = ColorStore.standard

    private struct FileVersion: Equatable {
        let modified: Date?
        let size: Int?
        let inode: Int?
    }

    // Only this queue owns the index cache. The menu and CLI share the file lock.
    func update(pid: pid_t) -> SidebarUpdate {
        do {
            let url = Inventory.indexURL
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let version = FileVersion(modified: attributes[.modificationDate] as? Date,
                                      size: attributes[.size] as? Int,
                                      inode: attributes[.systemFileNumber] as? Int)
            let indexChanged = inventory == nil || version != cachedVersion
            if indexChanged {
                inventory = Inventory(jsonl: try Data(contentsOf: url))
                cachedVersion = version
            }
            guard let inventory else { return SidebarUpdate() }
            let now = ProcessInfo.processInfo.systemUptime
            if indexChanged || now - foldersReadAt >= 1 {
                folders = try FolderCatalog.read()
                foldersReadAt = now
            }
            let ids = inventory.ordered.map(\.id)
            let colors = try store.update { $0.assignNew(ids, folders: folders) }
            let tracking = CodexSidebar.track(pid: pid, inventory: inventory)
            return SidebarUpdate(tracking: tracking, colors: colors)
        } catch {
            return SidebarUpdate(error: "Couldn’t read the chat index or color file. Run doctor for diagnostics.")
        }
    }
}

private final class ColorChoice: NSObject {
    let id: UUID
    let color: ChatColor?

    init(id: UUID, color: ChatColor?) {
        self.id = id
        self.color = color
    }
}

final class RainbowApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let overlay = Overlay()
    private let reader = SidebarReader()
    private let queue = DispatchQueue(label: "codex-rainbow.sidebar", qos: .userInitiated)
    private let geometryQueue = DispatchQueue(label: "codex-rainbow.geometry", qos: .userInteractive)
    private let auditQueue = DispatchQueue(label: "codex-rainbow.audit", qos: .utility)
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var update = SidebarUpdate()
    private var reading = false
    private var paused = false
    private var menuOpen = false
    private var generation = 0
    private var timer: Timer?
    private var geometryTimer: Timer?
    private var displayLink: AnyObject?
    private var displayed = SidebarSnapshot()
    private var checkingGeometry = false
    private var geometryFrames = 0
    private var lastAudit: Data?
    private let auditPath: String? // Only used by the local integration test.

    init(auditPath: String? = nil) {
        self.auditPath = auditPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Codex Rainbow")
        statusItem.button?.toolTip = "Codex Rainbow"
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspace.addObserver(self, selector: #selector(focusChanged), name: name, object: nil)
        }
        let timer = Timer(timeInterval: 0.65, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        if #available(macOS 14.0, *), let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(checkGeometry))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let geometryTimer = Timer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(checkGeometry),
                                      userInfo: nil, repeats: true)
            RunLoop.main.add(geometryTimer, forMode: .common)
            self.geometryTimer = geometryTimer
        }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
    }

    @objc private func checkGeometry() {
        guard !checkingGeometry, let tracking = update.tracking, !paused,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CodexSidebar.bundleID else { return }
        let started = generation
        checkingGeometry = true
        geometryQueue.async { [weak self] in
            let frame = CodexSidebar.currentFrame(of: tracking)
            DispatchQueue.main.async {
                guard let self else { return }
                self.checkingGeometry = false
                guard self.generation == started, !self.paused,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CodexSidebar.bundleID else { return }
                guard let frame else { self.hideOverlay(); self.audit(); return }
                if frame.rows != self.displayed.rows { self.geometryFrames += 1 }
                self.displayed = frame
                self.overlay.render(rows: frame.rows, in: frame.viewport, colors: self.update.colors)
                self.audit()
            }
        }
    }

    private func hideOverlay() {
        displayed = SidebarSnapshot()
        overlay.hide()
    }

    @objc private func focusChanged() {
        generation += 1
        update.tracking = nil
        hideOverlay()
        refresh()
    }

    @objc private func refresh() {
        guard !paused, AXIsProcessTrusted() else { hideOverlay(); audit(); return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == CodexSidebar.bundleID else {
            if !menuOpen { hideOverlay() }
            audit()
            return
        }
        guard !reading else { return }

        reading = true
        let pid = front.processIdentifier
        let started = generation
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.reader.update(pid: pid)
            DispatchQueue.main.async {
                self.reading = false
                guard !self.paused, started == self.generation,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                let prior = self.update.tracking
                self.update = result
                if self.update.tracking == nil { self.update.tracking = prior }
                self.checkGeometry()
                self.audit()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; refresh() }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(NSMenuItem(title: "Codex Rainbow", action: nil, keyEquivalent: ""))

        if !AXIsProcessTrusted() {
            add("Grant Accessibility Access…", action: #selector(requestAccess))
        } else {
            let rows = displayed.rows.sorted { $0.rect.minY < $1.rect.minY }
            var shown = Set<UUID>()
            let uniqueRows = rows.filter { shown.insert($0.id).inserted }
            if let error = update.error {
                menu.addItem(NSMenuItem(title: error, action: nil, keyEquivalent: ""))
            } else if uniqueRows.isEmpty {
                menu.addItem(NSMenuItem(title: "Open the Codex chat sidebar to choose a color", action: nil, keyEquivalent: ""))
            } else {
                let picker = NSMenuItem(title: "Set Chat Color", action: nil, keyEquivalent: "")
                let chats = NSMenu()
                for row in uniqueRows {
                    let current = update.colors.color(for: row.id)
                    let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
                    item.image = current?.swatch
                    let choices = NSMenu()
                    for color in ChatColor.allCases {
                        let choice = colorItem(color.name, id: row.id, color: color)
                        choice.image = color.swatch
                        choice.state = update.colors.override(for: row.id) == color ? .on : .off
                        choices.addItem(choice)
                    }
                    choices.addItem(.separator())
                    let automatic = colorItem("Use Rainbow Color", id: row.id, color: nil)
                    automatic.state = update.colors.override(for: row.id) == nil ? .on : .off
                    choices.addItem(automatic)
                    item.submenu = choices
                    chats.addItem(item)
                }
                picker.submenu = chats
                menu.addItem(picker)
            }
            add(paused ? "Show Sidebar Colors" : "Hide Sidebar Colors", action: #selector(toggle))
        }
        menu.addItem(.separator())
        add("Quit Codex Rainbow", action: #selector(quit))
    }

    private func add(_ title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func colorItem(_ title: String, id: UUID, color: ChatColor?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(setColor), keyEquivalent: "")
        item.target = self
        item.representedObject = ColorChoice(id: id, color: color)
        return item
    }

    @objc private func setColor(_ item: NSMenuItem) {
        guard let choice = item.representedObject as? ColorChoice else { return }
        let id = choice.id
        let color = choice.color
        queue.async { [weak self] in
            do {
                try ColorStore.standard.update { $0.set(color, for: [id]) }
                DispatchQueue.main.async { self?.refresh() }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t save the chat color"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @objc private func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func toggle() {
        paused.toggle()
        generation += 1
        if paused { hideOverlay() } else { refresh() }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func audit() {
        guard let auditPath else { return }
        let record: [String: Any] = [
            "accessibility": AXIsProcessTrusted(),
            "matchedRows": displayed.rows.count,
            "unmatchedRows": displayed.unmatched,
            "sidebarFound": displayed.foundSidebar,
            "geometryFrames": geometryFrames,
            "codexFrontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CodexSidebar.bundleID,
            "overlayVisible": overlay.isVisible,
            "paintedRows": overlay.paintedRows
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), data != lastAudit else { return }
        lastAudit = data
        auditQueue.async {
            try? data.write(to: URL(fileURLWithPath: auditPath), options: .atomic)
        }
    }
}
