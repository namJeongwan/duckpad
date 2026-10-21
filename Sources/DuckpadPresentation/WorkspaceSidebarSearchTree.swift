import DuckpadApplication
import Foundation

@MainActor
enum WorkspaceSidebarSearchTree {
    static func build(roots: [WorkspaceRoot], files: [WorkspaceBrowserEntry]) -> [WorkspaceSidebarNode] {
        roots.compactMap { root in
            let top = WorkspaceSidebarNode(root: root)
            top.children = []
            var nodes = ["": top]
            for file in files where file.rootID == root.id {
                let parts = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { continue }
                var path = "", parent = top
                for (offset, part) in parts.enumerated() {
                    path = path.isEmpty ? String(part) : path + "/" + part
                    if let existing = nodes[path] { parent = existing; continue }
                    let entry = WorkspaceBrowserEntry(rootID: root.id, relativePath: path, name: String(part),
                        kind: offset == parts.count - 1 ? .file : .directory)
                    let node = WorkspaceSidebarNode(entry: entry, parent: parent)
                    node.children = []
                    parent.children?.append(node); nodes[path] = node; parent = node
                }
            }
            for node in nodes.values {
                node.children?.sort {
                    if $0.kind != $1.kind { return $0.kind == .directory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
            return top.children?.isEmpty == false ? top : nil
        }
    }
}
