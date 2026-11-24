import AppKit
import Darwin
import Foundation

enum ChatColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, turquoise, blue, indigo, violet

    var name: String { rawValue.capitalized }

    private static let tintOpacity: CGFloat = 0.23

    var cssTint: String {
        let color = ink
        let values = [color.redComponent, color.greenComponent, color.blueComponent, Self.tintOpacity]
        return "#" + values.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    var ink: NSColor {
        let rgb: UInt32
        switch self {
        case .red:       rgb = 0xEE5267
        case .orange:    rgb = 0xF28A38
        case .yellow:    rgb = 0xE6B632
        case .green:     rgb = 0x55BE67
        case .turquoise: rgb = 0x29C7B8
        case .blue:      rgb = 0x4DA2F5
        case .indigo:    rgb = 0x7678F6
        case .violet:    rgb = 0xC471ED
        }
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                       green: Double((rgb >> 8) & 255) / 255,
                       blue: Double(rgb & 255) / 255, alpha: 1)
    }

    func draw(in bounds: CGRect) {
        let rect = bounds.insetBy(dx: 1, dy: 0.5)
        guard rect.width >= 14, rect.height >= 1 else { return }
        let radius = min(7, rect.height / 4)
        ink.withAlphaComponent(Self.tintOpacity).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    var swatch: NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            ink.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }
}

struct RainbowError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct Chat: Decodable, Encodable, Equatable {
    let id: UUID
    let title: String

    enum CodingKeys: String, CodingKey {
        case id
        case title = "thread_name"
    }

    var createdOrder: String? {
        let value = id.uuidString
        return value[value.index(value.startIndex, offsetBy: 14)] == "7" ? String(value.prefix(13)) : nil
    }
}

func titleKey(_ title: String) -> String {
    title.split(whereSeparator: \.isWhitespace).joined(separator: " ").precomposedStringWithCanonicalMapping
}

struct Inventory {
    let ordered: [Chat]
    let idsByTitle: [String: [UUID]]

    init(jsonl: Data) {
        var byID: [UUID: Chat] = [:]
        var positions: [UUID: Int] = [:]
        let decoder = JSONDecoder()
        for line in jsonl.split(separator: 10) {
            guard let entry = try? decoder.decode(Chat.self, from: Data(line)) else { continue }
            if positions[entry.id] == nil { positions[entry.id] = positions.count }
            // A later index record can rename a chat without changing its place in the cycle.
            byID[entry.id] = entry
        }
        ordered = byID.values.sorted { a, b in
            let aTime = a.createdOrder ?? ""
            let bTime = b.createdOrder ?? ""
            if aTime != bTime { return aTime < bTime }
            return positions[a.id, default: 0] < positions[b.id, default: 0]
        }
        idsByTitle = Dictionary(grouping: ordered.filter { !titleKey($0.title).isEmpty }) { titleKey($0.title) }
            .mapValues { $0.map(\.id) }
    }

    func identify(title: String) -> UUID? {
        let matches = idsByTitle[titleKey(title)] ?? []
        return matches.count == 1 ? matches.first : nil
    }

    static var indexURL: URL {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return codexHome.appendingPathComponent("session_index.jsonl")
    }
}

struct Assignments: Codable, Equatable {
    var version = 1
    private(set) var next = 0
    private var rainbow: [String: ChatColor] = [:]
    private var overrides: [String: ChatColor] = [:]
    // Optional so existing installations keep their saved assignments on upgrade.
    private var nextByFolder: [String: Int]?

    mutating func assignNew(_ ids: [UUID], folders: FolderCatalog) {
        var positions = nextByFolder ?? [:]
        let palette = ChatColor.allCases
        let active = ids.filter { !folders.archived.contains($0) }

        if nextByFolder == nil {
            for id in active where rainbow[id.uuidString] != nil {
                let folder = folders.folder(of: id)
                positions[folder] = (positions[folder, default: 0] + 1) % palette.count
            }
        }
        for id in active where rainbow[id.uuidString] == nil {
            let folder = folders.folder(of: id)
            let position = positions[folder, default: 0]
            rainbow[id.uuidString] = palette[position]
            positions[folder] = (position + 1) % palette.count
            next = (next + 1) % palette.count
        }
        nextByFolder = positions
    }

    mutating func resetRainbow(_ ids: [UUID], folders: FolderCatalog, protecting extra: Set<UUID>) -> ResetReport {
        let pinned = folders.pinned.union(extra)
        let active = ids.filter { !folders.archived.contains($0) }
        let reset = folders.resetOrder(for: active.filter { !pinned.contains($0) })
        for id in reset {
            rainbow.removeValue(forKey: id.uuidString)
            overrides.removeValue(forKey: id.uuidString)
        }
        nextByFolder = [:]
        next = 0
        assignNew(reset, folders: folders)
        return ResetReport(chats: reset.count, folders: Set(reset.map(folders.folder(of:))).count,
                           pinnedPreserved: active.filter(pinned.contains).count)
    }

    func color(for id: UUID) -> ChatColor? { overrides[id.uuidString] ?? rainbow[id.uuidString] }

    func override(for id: UUID) -> ChatColor? { overrides[id.uuidString] }

    mutating func set(_ color: ChatColor?, for ids: [UUID]) {
        for id in ids { overrides[id.uuidString] = color }
    }

    func validate() throws {
        let validFolderPositions = nextByFolder?.values.allSatisfy(ChatColor.allCases.indices.contains) ?? true
        guard version == 1, ChatColor.allCases.indices.contains(next), validFolderPositions else {
            throw RainbowError("The color file has an unsupported version or palette position.")
        }
    }
}

struct ColorStore {
    let directory: URL

    static var standard: ColorStore {
        let url = ProcessInfo.processInfo.environment["CODEX_RAINBOW_STATE_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Rainbow")
        return ColorStore(directory: url)
    }

    @discardableResult
    func update(_ edit: (inout Assignments) -> Void) throws -> Assignments {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent("colors.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }

        let url = directory.appendingPathComponent("colors.json")
        let previous: Assignments
        do {
            previous = try JSONDecoder().decode(Assignments.self, from: Data(contentsOf: url))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            previous = Assignments()
        }
        try previous.validate()
        var result = previous
        edit(&result)
        if result != previous {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: url, options: .atomic)
        }
        return result
    }
}
