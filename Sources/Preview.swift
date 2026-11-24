import AppKit
import WebKit

func runPreview(checkAt snapshotPath: String? = nil, reportAt reportPath: String? = nil) throws {
    let inventory = try loadInventory()
    let folders = try FolderCatalog.read()
    let colors = try ColorStore.standard.update { $0.assignNew(inventory.ordered.map(\.id), folders: folders) }
    let delegate = RainbowPreview(inventory: inventory, folders: folders, colors: colors, snapshotPath: snapshotPath, reportPath: reportPath)
    let application = NSApplication.shared
    application.setActivationPolicy(snapshotPath == nil ? .regular : .prohibited)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}

final class RainbowPreview: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    static let bundleID = "tools.codexrainbow.preview"

    private let inventory: Inventory
    private let folders: FolderCatalog
    private let colors: Assignments
    private let snapshotPath: String?
    private let reportPath: String?
    private let allowedChatIDs: Set<UUID>
    private var window: NSWindow?

    init(inventory: Inventory, folders: FolderCatalog, colors: Assignments, snapshotPath: String?, reportPath: String?) {
        self.inventory = inventory
        self.folders = folders
        self.colors = colors
        self.snapshotPath = snapshotPath
        self.reportPath = reportPath
        self.allowedChatIDs = Set(inventory.ordered.map(\.id)).subtracting(folders.archived)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let size = NSSize(width: 520, height: 665)
        let location = snapshotPath == nil ? NSPoint.zero : NSPoint(x: -20000, y: -20000)
        let content = NSRect(origin: location, size: size)
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.navigationDelegate = self

        let window = NSWindow(contentRect: content, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        self.window = window
        window.title = "Rainbow Preview"
        window.contentMinSize = NSSize(width: 345, height: 330)
        window.contentView = web
        if snapshotPath == nil {
            installMenu()
            window.center()
            window.makeKeyAndOrderFront(nil)
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(4) }
        }
        web.loadHTMLString(page(), baseURL: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func installMenu() {
        let quit = NSMenuItem(title: "Quit Rainbow Preview", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        let applicationMenu = NSMenu()
        applicationMenu.addItem(quit)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let bar = NSMenu()
        let application = NSMenuItem()
        application.submenu = applicationMenu
        bar.addItem(application)
        let editItem = NSMenuItem()
        editItem.submenu = edit
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        if action.navigationType == .linkActivated, url.scheme == "codex", url.host == "threads",
           let id = UUID(uuidString: String(url.path.dropFirst())), allowedChatIDs.contains(id) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    private func groupLabel(_ key: String) -> String {
        if key == "pinned" { return "Pinned" }
        if key == "recents" { return "Recents" }
        return folders.displayNames[key] ?? (key.hasPrefix("section:") ? "Folder" : "Project")
    }

    private func page() -> String {
        let chats = inventory.ordered.filter { allowedChatIDs.contains($0.id) }
        let byID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        let sorted = folders.resetOrder(for: chats.map(\.id)).compactMap { byID[$0] }
        let groups = Dictionary(grouping: sorted) { chat in folders.pinned.contains(chat.id) ? "pinned" : folders.folder(of: chat.id) }
        let keys = groups.keys.sorted { a, b in
            if a == b { return false }
            if a == "pinned" { return true }
            if b == "pinned" { return false }
            if b == "recents" { return true }
            if a == "recents" { return false }
            let comparison = groupLabel(a).localizedStandardCompare(groupLabel(b))
            return comparison == .orderedSame ? a < b : comparison == .orderedAscending
        }
        let entries = keys.map { key in
            let rows = groups[key, default: []].map { chat in
                let id = chat.id.uuidString.lowercased()
                let title = htmlText(chat.title.isEmpty ? "Untitled chat" : chat.title)
                return """
                    <a class="chat" href="codex://threads/\(id)" data-app-action-sidebar-thread-row
                       data-app-action-sidebar-thread-id="local:\(id)"><span class="label">\(title)</span><span class="arrow" aria-hidden="true">↗</span></a>
                    """
            }.joined(separator: "\n")
            return "<section><h2>\(htmlText(groupLabel(key)))</h2>\(rows)</section>"
        }.joined(separator: "\n")
        return """
            <!doctype html><html lang="en"><head>
            <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-rainbow'; base-uri 'none'; form-action 'none'">
            <style>
            :root { color-scheme: light dark; --surface:#f7f6f1; --ink:#24221f; --sub:#5f5a50; --line:#dedace; --neutral:#eeebe3; --hover:#e7e2d7; }
            @media (prefers-color-scheme:dark) { :root { --surface:#201e1b; --ink:#f3eee6; --sub:#c3b9a9; --line:#51493e; --neutral:#322e29; --hover:#3e3830; } }
            * { box-sizing:border-box; }
            body { margin:0; height:100vh; display:flex; flex-direction:column; color:var(--ink); background:var(--surface); font:14px -apple-system,sans-serif; }
            header { display:flex; flex-direction:column; gap:13px; padding:21px 23px 16px; border-bottom:1px solid var(--line); }
            h1 { margin:0; font:28px Georgia,serif; letter-spacing:-.5px; }
            input { max-width:100%; appearance:none; padding:9px 12px; border:1px solid var(--line); border-radius:7px; background:var(--neutral); color:var(--ink); font:inherit; }
            input::placeholder { color:var(--sub); opacity:1; }
            main { flex:1; min-height:0; overflow-y:auto; padding:2px 23px 29px; }
            section { margin:19px 0 23px; }
            h2 { font:600 12px -apple-system,sans-serif; margin:0 0 10px; color:var(--sub); }
            .chat { display:flex; align-items:center; justify-content:space-between; gap:16px; padding:12px 14px; border-radius:7px; background-color:var(--neutral); color:var(--ink); text-decoration:none; margin-bottom:5px; }
            .chat:hover { background-color:var(--hover); }
            .chat:focus-visible, input:focus-visible { outline:2px solid #8a684a; outline-offset:1px; }
            .label { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
            .arrow { flex:none; color:var(--sub); }
            #empty { color:var(--sub); margin-top:22px; }
            [hidden] { display:none !important; }
            \(sidebarCSS(for: inventory, colors: colors))
            </style></head>
            <body><header><h1>Sessions</h1><input type="search" id="search" placeholder="Find a session" aria-label="Find a session"></header>
            <main id="sessions" aria-label="Local Codex sessions">\(entries)<p id="empty"\(chats.isEmpty ? "" : " hidden")>No matching sessions</p></main>
            <script nonce="rainbow">
            const search = document.querySelector("#search");
            const sections = [...document.querySelectorAll("section")].map(section => ({
                section, folder: section.firstElementChild.textContent.toLocaleLowerCase(),
                rows: [...section.querySelectorAll(".chat")].map(row => ({row, title:row.firstElementChild.textContent.toLocaleLowerCase()}))
            }));
            search.addEventListener("input", () => {
                const filter = search.value.trim().toLocaleLowerCase();
                let found = false;
                for (const {section, folder, rows} of sections) {
                    let visible = false;
                    for (const {row, title} of rows) {
                        row.hidden = !title.includes(filter) && !folder.includes(filter);
                        visible ||= !row.hidden;
                    }
                    section.hidden = !visible;
                    found ||= visible;
                }
                document.querySelector("#empty").hidden = found;
            });
            </script></body></html>
            """
    }

    private func htmlText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let reportPath {
            webView.evaluateJavaScript("""
                (() => {
                    const pane = document.querySelector("main");
                    const rows = [...pane.querySelectorAll(".chat")];
                    const colored = rows.filter(row => getComputedStyle(row).backgroundImage !== "none").length;
                    const row = rows.find(row => getComputedStyle(row).backgroundImage !== "none");
                    let scrolled = 0, drift = 0, colorHeld = false;
                    if (row) {
                        const label = row.querySelector(".label");
                        const start = pane.scrollTop;
                        const before = row.getBoundingClientRect().y - label.getBoundingClientRect().y;
                        const color = getComputedStyle(row).backgroundImage;
                        pane.scrollTop = start + 180;
                        scrolled = pane.scrollTop - start;
                        drift = Math.abs(row.getBoundingClientRect().y - label.getBoundingClientRect().y - before);
                        colorHeld = getComputedStyle(row).backgroundImage === color;
                        pane.scrollTop = start;
                    }
                    return {rows:rows.length, colored, groups:pane.querySelectorAll("section").length,
                            scrollable:pane.scrollHeight > pane.clientHeight, scrolled, drift, colorHeld};
                })()
                """) { value, _ in
                guard let report = value as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
                try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            }
        }
        guard let snapshotPath else { return }
        webView.evaluateJavaScript("""
            (() => {
                const pane = document.querySelector("#sessions");
                const rows = [...pane.querySelectorAll(".chat")].map(row => {
                    const label = row.querySelector(".label");
                    return { row, label, color: getComputedStyle(row).backgroundImage,
                             y: row.getBoundingClientRect().y, textY: label.getBoundingClientRect().y };
                });
                let drift = 0, errors = 0, traveled = 0;
                for (const offset of [1, 17, 116, 284, 700, 1200, 845, 77, 0]) {
                    pane.scrollTop = offset;
                    traveled = Math.max(traveled, pane.scrollTop);
                    for (const {row, label, color, y, textY} of rows) {
                        drift = Math.max(drift, Math.abs(row.getBoundingClientRect().y - y - label.getBoundingClientRect().y + textY));
                        if (color === "none" || color !== getComputedStyle(row).backgroundImage) errors++;
                    }
                }
                pane.scrollTop = 83;
                return {count: rows.length, traveled, drift, errors};
            })()
            """) { value, error in
            guard error == nil, let result = value as? [String: NSNumber],
                  (result["count"]?.intValue ?? 0) >= 24, (result["traveled"]?.intValue ?? 0) >= 250,
                  (result["drift"]?.doubleValue ?? 1) < 0.01, result["errors"]?.intValue == 0 else {
                print("Preview check failed:", error?.localizedDescription ?? String(describing: value))
                exit(2)
            }
            print(result)
            webView.takeSnapshot(with: nil) { image, _ in
                guard let tiff = image?.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]),
                      (try? png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)) != nil else { exit(3) }
                exit(0)
            }
        }
    }
}
