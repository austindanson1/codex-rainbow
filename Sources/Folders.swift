import Foundation
import SQLite3

struct FolderCatalog {
    private(set) var membership: [UUID: String] = [:]
    private(set) var pinned: Set<UUID> = []
    private(set) var archived: Set<UUID> = []
    private(set) var savedOrder: [String: [UUID]] = [:]
    private(set) var displayNames: [String: String] = [:]
    private(set) var hasPinMetadata = false

    func folder(of id: UUID) -> String { membership[id] ?? "recents" }

    func resetOrder(for ordered: [UUID]) -> [UUID] {
        let available = Set(ordered)
        var included = Set<UUID>()
        let manual = savedOrder.keys.sorted().flatMap { key in
            (savedOrder[key] ?? []).filter { available.contains($0) && folder(of: $0) == key && included.insert($0).inserted }
        }
        return manual + ordered.filter { included.insert($0).inserted }
    }

    static func read(home: URL = Inventory.indexURL.deletingLastPathComponent()) throws -> FolderCatalog {
        var catalog = FolderCatalog()
        catalog.addLegacyProjectMembership(home: home)
        try catalog.readCurrentMetadata(home: home)
        return catalog
    }

    private mutating func readCurrentMetadata(home: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        let databases = entries.compactMap { path -> (Int, URL)? in
            let name = path.deletingPathExtension().lastPathComponent
            guard path.pathExtension == "sqlite", name.hasPrefix("state_"),
                  let schema = Int(name.dropFirst(6)) else { return nil }
            return (schema, path)
        }
        guard let (_, file) = databases.max(by: { $0.0 < $1.0 }) else { return }

        var db: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard status == SQLITE_OK else { throw RainbowError("Couldn’t open Codex’s folder metadata read-only.") }
        sqlite3_busy_timeout(db, 100)

        func columns(_ query: String) throws -> Set<String> {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                throw RainbowError("Couldn’t read Codex’s folder schema.")
            }
            defer { sqlite3_finalize(statement) }
            var names = Set<String>()
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
                case SQLITE_DONE: return names
                default: throw RainbowError("Couldn’t finish reading Codex’s folder schema.")
                }
            }
        }
        let fields = try columns("PRAGMA table_info(threads)")
        guard fields.contains("id") else { throw RainbowError("This Codex build’s chat metadata format is unsupported.") }
        let sections = try columns("PRAGMA table_info(thread_sections)")
        let joinSections = fields.contains("thread_section_id") && sections.isSuperset(of: ["id", "name"])
        func field(_ name: String) -> String { fields.contains(name) ? "t." + name : "NULL" }
        let query = """
            SELECT t.id, \(field("project_id")), \(field("thread_section_id")), \(field("archived")),
                   \(field("is_pinned")), \(joinSections ? "s.name" : "NULL"), \(field("section_position")), \(field("cwd"))
            FROM threads AS t \(joinSections ? "LEFT JOIN thread_sections AS s ON s.id = t.thread_section_id" : "")
            ORDER BY \(field("thread_section_id")), \(field("section_position")), \(field("created_at"))
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw RainbowError("This Codex build’s folder metadata format is unsupported.")
        }
        defer { sqlite3_finalize(statement) }

        func string(_ column: Int32) -> String? {
            guard let value = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: value)
        }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE:
                hasPinMetadata = fields.contains("is_pinned")
                readProjectNames(db: db)
                return
            case SQLITE_ROW:
                guard let rawID = string(0), let id = UUID(uuidString: rawID) else { continue }
                let isPinned = sqlite3_column_int(statement, 4) != 0 || string(5)?.lowercased() == "pinned"
                if isPinned { pinned.insert(id) }
                if sqlite3_column_int(statement, 3) != 0 { archived.insert(id) }
                if let section = string(2), !isPinned {
                    let folder = "section:" + section
                    if let label = string(5) { displayNames[folder] = label }
                    membership[id] = folder
                    if sqlite3_column_type(statement, 6) != SQLITE_NULL {
                        savedOrder[folder, default: []].append(id)
                    }
                } else if let project = string(1) {
                    membership[id] = "project:" + project
                } else if !fields.contains("project_id"), membership[id] == nil, let cwd = string(7), !cwd.isEmpty {
                    membership[id] = "cwd:" + cwd
                    displayNames["cwd:" + cwd] = URL(fileURLWithPath: cwd).lastPathComponent
                }
            default:
                throw RainbowError("Couldn’t finish reading Codex’s folder metadata.")
            }
        }
    }

    private mutating func readProjectNames(db: OpaquePointer?) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, name FROM projects", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) else { continue }
            displayNames["project:" + String(cString: id)] = String(cString: title)
        }
    }

    private mutating func addLegacyProjectMembership(home: URL) {
        // Some desktop projects and their manual row orders are still in the desktop metadata.
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".codex-global-state.json")),
              let desktop = try? JSONDecoder().decode(DesktopProjects.self, from: data) else { return }
        var aliases: [String: Set<String>] = [:]
        for host in desktop.migratedProjects?.values ?? [:].values {
            for (old, new) in host { aliases[old, default: []].insert(new) }
        }
        func canonical(_ project: String) -> String {
            guard let match = aliases[project], match.count == 1, let current = match.first else { return project }
            return current
        }
        for (rawID, assignment) in desktop.membership ?? [:] where assignment.projectKind == "local" {
            guard let id = UUID(uuidString: rawID), membership[id] == nil else { continue }
            membership[id] = "project:" + canonical(assignment.projectId)
        }
        for (id, project) in desktop.projects ?? [:] {
            let key = "project:" + canonical(id)
            if displayNames[key] == nil { displayNames[key] = project.name }
        }
        for key in (desktop.order ?? [:]).keys.sorted() {
            let folder = "project:" + canonical(key)
            savedOrder[folder, default: []] += desktop.order?[key]?.threadIds.compactMap(UUID.init(uuidString:)) ?? []
        }
    }
}

private struct DesktopProjects: Decodable {
    struct Assignment: Decodable {
        let projectKind: String
        let projectId: String
    }
    struct Order: Decodable {
        let threadIds: [String]
    }

    struct Project: Decodable {
        let name: String
    }

    let membership: [String: Assignment]?
    let projects: [String: Project]?
    let migratedProjects: [String: [String: String]]?
    let order: [String: Order]?

    enum CodingKeys: String, CodingKey {
        case membership = "thread-project-assignments"
        case projects = "local-projects"
        case migratedProjects = "app-server-project-id-by-legacy-project-id-by-host"
        case order = "sidebar-project-thread-orders"
    }
}

struct ResetReport: Encodable {
    let chats: Int
    let folders: Int
    let pinnedPreserved: Int
}
