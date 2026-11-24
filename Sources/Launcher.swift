import AppKit
import Foundation

enum RainbowLauncher {
    static let bundleID = "tools.codexrainbow.launcher"
    static let fm = FileManager.default

    static func codex() throws -> Bundle {
        let paths = ["/Applications/Codex.app", "/Applications/ChatGPT.app"].map { URL(fileURLWithPath: $0) }
        let urls = paths + [NSWorkspace.shared.urlForApplication(withBundleIdentifier: CodexSidebar.bundleID)].compactMap { $0 }
        guard let bundle = urls.compactMap({ Bundle(url: $0) }).first(where: { $0.bundleIdentifier == CodexSidebar.bundleID }),
              let executable = bundle.executableURL, fm.isExecutableFile(atPath: executable.path) else {
            throw RainbowError("Install the Codex desktop app before opening Codex Rainbow.")
        }
        return bundle
    }

    static func runtime(in codex: Bundle) throws -> URL {
        let candidates: [String?] = [codex.resourceURL?.appendingPathComponent("node").path, "/opt/homebrew/bin/node", "/usr/local/bin/node"]
        for path in candidates.compactMap({ $0 }) where fm.isExecutableFile(atPath: path) {
            let node = URL(fileURLWithPath: path)
            let check = Process(), pipe = Pipe()
            check.executableURL = node
            check.arguments = ["--version"]
            check.standardOutput = pipe
            check.standardError = FileHandle.nullDevice
            try check.run()
            check.waitUntilExit()
            let version = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if check.terminationStatus == 0, version.first == "v",
               let major = Int(version.dropFirst().prefix(while: { $0.isNumber })), major >= 20 { return node }
        }
        throw RainbowError("This Codex build needs Node.js 20 or newer installed in /opt/homebrew/bin or /usr/local/bin.")
    }

    static func open() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = LauncherDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

private final class LauncherDelegate: NSObject, NSApplicationDelegate {
    private var controller: Process?
    private var codex: Bundle?

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Codex Rainbow"
        alert.informativeText = error.localizedDescription
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let bundle = try RainbowLauncher.codex()
            codex = bundle
            let customProfile = ProcessInfo.processInfo.environment["CODEX_ELECTRON_USER_DATA_PATH"]
            if customProfile == nil && !NSRunningApplication.runningApplications(withBundleIdentifier: CodexSidebar.bundleID).isEmpty {
                // Relaunching an already-running app restores its windows without interrupting jobs.
                NSWorkspace.shared.openApplication(at: bundle.bundleURL, configuration: .init()) { _, error in
                    DispatchQueue.main.async {
                        if let error { self.report(error) } else { NSApp.terminate(nil) }
                    }
                }
                return
            }
            guard let script = Bundle.main.url(forResource: "controller", withExtension: "mjs"),
                  let cli = Bundle.main.executableURL, let binary = bundle.executableURL else {
                throw RainbowError("Reinstall Codex Rainbow to restore its launcher files.")
            }
            let process = Process()
            process.executableURL = try RainbowLauncher.runtime(in: bundle)
            process.arguments = [script.path, binary.path, cli.path]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.terminationHandler = { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
            try process.run()
            controller = process
        } catch { report(error) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let bundle = codex, !NSRunningApplication.runningApplications(withBundleIdentifier: CodexSidebar.bundleID).isEmpty {
            NSWorkspace.shared.openApplication(at: bundle.bundleURL, configuration: .init())
        }
        return false
    }
}
