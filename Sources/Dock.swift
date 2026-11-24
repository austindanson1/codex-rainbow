import AppKit
import Foundation

enum RainbowDock {
    private static let domain = "com.apple.dock" as CFString
    private static let key = "persistent-apps" as CFString
    private typealias Tile = [String: Any]

    private static func tiles() throws -> [Tile] {
        guard CFPreferencesAppSynchronize(domain),
              let entries = CFPreferencesCopyAppValue(key, domain) as? [Tile] else {
            throw RainbowError("Couldn’t read the Dock. You can drag Codex Rainbow from Applications into the Dock.")
        }
        return entries
    }

    private static func path(_ tile: Tile) -> String? {
        let data = tile["tile-data"] as? Tile
        let file = data?["file-data"] as? Tile
        guard let raw = file?["_CFURLString"] as? String else { return nil }
        return URL(string: raw)?.standardizedFileURL.path
    }

    private static func tile(_ url: URL) -> Tile {
        ["tile-type": "file-tile", "tile-data": [
            "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15],
            "file-type": 41,
            "file-label": url.deletingPathExtension().lastPathComponent,
            "bundle-identifier": Bundle(url: url)?.bundleIdentifier ?? ""
        ] as Tile]
    }

    static func configure(install: Bool) throws {
        let launcher = Bundle.main.bundleURL
        guard Bundle.main.bundleIdentifier == RainbowLauncher.bundleID else { throw RainbowError("Run this command from the installed launcher.") }
        let original = try? RainbowLauncher.codex().bundleURL
        if install && original == nil { throw RainbowError("Install Codex first, then rerun the Rainbow installer.") }
        let before = try tiles()
        var entries = before
        let own = entries.firstIndex { path($0) == launcher.standardizedFileURL.path }
        let stock = original.flatMap { url in entries.firstIndex { path($0) == url.standardizedFileURL.path } }
        let prefs = UserDefaults.standard
        let replaced = "RainbowReplacedCodexDockTile"
        if install {
            if own != nil { return }
            prefs.set(stock != nil, forKey: replaced)
            if let stock { entries[stock] = tile(launcher) } else { entries.append(tile(launcher)) }
        } else {
            guard let own else { return }
            if prefs.bool(forKey: replaced), stock == nil, let original { entries[own] = tile(original) }
            else { entries.remove(at: own) }
        }
        // Refuse a stale write if someone rearranged their Dock during setup.
        guard try (tiles() as NSArray).isEqual(to: before) else { throw RainbowError("The Dock changed during setup. Run the installer again.") }
        CFPreferencesSetAppValue(key, entries as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain),
              try tiles().contains(where: { path($0) == launcher.standardizedFileURL.path }) == install else {
            throw RainbowError("The Dock preference write could not be verified.")
        }
        if !install { prefs.removeObject(forKey: replaced) }
        prefs.synchronize()
        // macOS immediately relaunches the Dock and loads its new tile list.
        for dock in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
            dock.terminate()
        }
    }
}
