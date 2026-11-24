import Foundation

func sidebarCSS(for inventory: Inventory, colors: Assignments) -> String {
    let assigned = inventory.ordered.compactMap { chat in
        colors.color(for: chat.id).map { (id: chat.id, color: $0) }
    }
    let groups = Dictionary(grouping: assigned, by: \.color)
    let rules = ChatColor.allCases.compactMap { color -> String? in
        guard let group = groups[color] else { return nil }
        let selectors = group.map { assignment in
            let id = assignment.id.uuidString.lowercased()
            return "[data-app-action-sidebar-thread-row][data-app-action-sidebar-thread-id^=\"local:\"][data-app-action-sidebar-thread-id$=\":\(id)\" i]"
        }
        let fill = color.cssTint
        return selectors.joined(separator: ",\n") + " {\n  background-image: linear-gradient(\(fill), \(fill));\n}"
    }
    return (["/* Codex Rainbow. Local chat IDs and colors only. */"] + rules).joined(separator: "\n\n")
}
