import AppKit
import ApplicationServices
import Foundation

let help = """
Codex Rainbow
  open the launcher             Start Codex with saved row colors
  rainbow sync-css              Assign newly indexed chats and export their row colors
  rainbow colors                List palette names in rainbow order
  rainbow css                   Export existing chat colors as a row stylesheet
  rainbow preview               Open a separate scrollable view of saved chat colors
  rainbow find [TITLE TEXT]     Find local Codex chats by title. Output is JSON
  rainbow set COLOR ID…         Assign a color to one or more exact chat IDs
  rainbow reset ID…             Restore the original rainbow color for chat IDs
  rainbow reset-rainbow [ID…]   Restart each folder’s rainbow, preserving pinned chats and these IDs
  rainbow doctor                Check macOS access and report sidebar match counts

Chat IDs can also be codex://thread/UUID links.
"""

struct SearchResult: Encodable {
    let id: String
    let title: String
    let color: ChatColor?
    let override: ChatColor?
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func loadInventory() throws -> Inventory {
    do {
        return Inventory(jsonl: try Data(contentsOf: Inventory.indexURL))
    } catch {
        throw RainbowError("Codex’s chat index is unavailable at \(Inventory.indexURL.path).")
    }
}

func chatIDs(for inputs: ArraySlice<String>, in inventory: Inventory) throws -> [UUID] {
    guard !inputs.isEmpty else { throw RainbowError("Provide at least one exact chat ID.") }
    let known = Set(inventory.ordered.map(\.id))
    return try inputs.map { input in
        let candidate: String
        if let url = URLComponents(string: input), url.scheme == "codex", ["thread", "threads"].contains(url.host ?? "") {
            candidate = String(url.path.dropFirst())
        } else {
            candidate = input
        }
        guard let id = UUID(uuidString: candidate), known.contains(id) else {
            throw RainbowError("A chat ID was invalid or missing from the local index. Run rainbow find for exact IDs.")
        }
        return id
    }
}

func runApp(auditPath: String? = nil) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = RainbowApp(auditPath: auditPath)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}

func main(_ args: [String]) throws {
    let store = ColorStore.standard
    switch args.first {
    case nil:
        if Bundle.main.bundleIdentifier == RainbowLauncher.bundleID {
            RainbowLauncher.open()
        } else if Bundle.main.bundleIdentifier == RainbowPreview.bundleID {
            try runPreview()
        } else {
            runApp()
        }
    case "preview":
        try runPreview()
    case "--preview-report":
        guard args.count == 2 else { throw RainbowError("Provide a preview report path.") }
        try runPreview(reportAt: args[1])
    case "--preview-check":
        guard args.count == 2 else { throw RainbowError("Provide a preview snapshot path.") }
        try runPreview(checkAt: args[1])
    case "--integration-audit":
        guard args.count == 2 else { throw RainbowError("Provide an audit file path.") }
        runApp(auditPath: args[1])
    case "--help", "-h", "help":
        print(help)
    case "colors":
        print(ChatColor.allCases.map(\.rawValue).joined(separator: " "))
    case "codex-path":
        print(try RainbowLauncher.codex().bundlePath)
    case "launcher-check":
        let codex = try RainbowLauncher.codex()
        _ = try RainbowLauncher.runtime(in: codex)
        guard Bundle.main.url(forResource: "controller", withExtension: "mjs") != nil else {
            throw RainbowError("The styling controller is missing.")
        }
        print("Codex and the Rainbow styling controller are available.")
    case "trash-launcher":
        guard Bundle.main.bundleIdentifier == RainbowLauncher.bundleID else { throw RainbowError("Expected the Rainbow launcher bundle.") }
        try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
    case "dock-install", "dock-remove":
        try RainbowDock.configure(install: args[0] == "dock-install")
    case "sync-css":
        let inventory = try loadInventory()
        let folders = try FolderCatalog.read()
        let colors = try store.update { $0.assignNew(inventory.ordered.map(\.id), folders: folders) }
        print(sidebarCSS(for: inventory, colors: colors))
    case "css":
        let inventory = try loadInventory()
        let colors = try store.update { _ in }
        print(sidebarCSS(for: inventory, colors: colors))
    case "find":
        let inventory = try loadInventory()
        let filter = args.dropFirst().joined(separator: " ")
        let folders = try FolderCatalog.read()
        let colors = try store.update { $0.assignNew(inventory.ordered.map(\.id), folders: folders) }
        let matches = inventory.ordered.reversed().filter {
            filter.isEmpty || $0.title.localizedStandardContains(filter)
        }
        try printJSON(matches.map {
            SearchResult(id: $0.id.uuidString.lowercased(), title: $0.title,
                         color: colors.color(for: $0.id), override: colors.override(for: $0.id))
        })
    case "set", "reset":
        let inventory = try loadInventory()
        let color: ChatColor?
        let ids: [UUID]
        if args[0] == "set" {
            guard args.count >= 3, let chosen = ChatColor(rawValue: args[1].lowercased()) else {
                throw RainbowError("Use rainbow set COLOR ID… from the available palette. Run rainbow colors.")
            }
            color = chosen
            ids = try chatIDs(for: args.dropFirst(2), in: inventory)
        } else {
            color = nil
            ids = try chatIDs(for: args.dropFirst(), in: inventory)
        }
        let folders = try FolderCatalog.read()
        let colors = try store.update { state in
            state.assignNew(inventory.ordered.map(\.id), folders: folders)
            state.set(color, for: ids)
        }
        let matches = Set(ids)
        try printJSON(inventory.ordered.filter { matches.contains($0.id) }.map {
            SearchResult(id: $0.id.uuidString.lowercased(), title: $0.title,
                         color: colors.color(for: $0.id), override: colors.override(for: $0.id))
        })
    case "reset-rainbow":
        let inventory = try loadInventory()
        let folders = try FolderCatalog.read()
        guard folders.hasPinMetadata else { throw RainbowError("Pin metadata is unavailable. Reset individual chats by ID.") }
        let extras = try args.dropFirst().map { raw in
            guard let id = UUID(uuidString: raw) else { throw RainbowError("Use exact UUIDs after reset-rainbow.") }
            return id
        }
        var report: ResetReport?
        try store.update { report = $0.resetRainbow(inventory.ordered.map(\.id), folders: folders, protecting: Set(extras)) }
        if let report { try printJSON(report) }
    case "doctor":
        let inventory = try loadInventory()
        // Validate the store without assigning or changing a color.
        _ = try store.update { _ in }
        let trusted = AXIsProcessTrusted()
        let codex = NSRunningApplication.runningApplications(withBundleIdentifier: CodexSidebar.bundleID).first
        print("Accessibility for this process: \(trusted ? "granted" : "requires a grant")")
        print("Indexed local chats: \(inventory.ordered.count)")
        if trusted, let codex {
            let result = CodexSidebar.scan(pid: codex.processIdentifier, inventory: inventory, allowMainWindow: true)
            print("Sidebar: \(result.foundSidebar ? "found" : "unavailable")")
            print("Visible chat rows: \(result.rows.count) matched, \(result.unmatched) unresolved")
        } else {
            print("Codex desktop: \(codex == nil ? "closed" : "running")")
        }
    default:
        throw RainbowError("Unknown command. Run rainbow --help.")
    }
}

do {
    try main(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data(("Codex Rainbow: \(error.localizedDescription)\n").utf8))
    exit(1)
}
