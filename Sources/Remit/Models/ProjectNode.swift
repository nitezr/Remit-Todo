import Foundation

/// A project plus its sub-projects. Nesting is a Remit-layer concept -- EventKit reminder lists
/// cannot contain other lists -- so the parent link comes from `ProjectMetadata.parentID`.
struct ProjectNode: Identifiable {
    var project: RemitProject
    var depth: Int
    var children: [ProjectNode]

    var id: String { project.id }
}

enum ProjectTree {
    /// Builds the nested list. A project whose `parentID` points at something that no longer exists
    /// falls back to top level rather than disappearing.
    ///
    /// The `ancestors` set is a cycle guard: two projects each set as the other's parent would
    /// otherwise recurse forever. The Glaze build hit the same hazard (`project-tree.ts`).
    static func build(
        projects: [RemitProject],
        parents: [String: String],
        order: [String] = []
    ) -> [ProjectNode] {
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var childrenOf: [String: [RemitProject]] = [:]
        var topLevel: [RemitProject] = []

        for project in projects {
            if let parentID = parents[project.id], parentID != project.id, byID[parentID] != nil {
                childrenOf[parentID, default: []].append(project)
            } else {
                topLevel.append(project)
            }
        }

        let orderIndex = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        func bySavedOrder(_ lhs: RemitProject, _ rhs: RemitProject) -> Bool {
            switch (orderIndex[lhs.id], orderIndex[rhs.id]) {
            case let (left?, right?): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }

        func node(_ project: RemitProject, depth: Int, ancestors: Set<String>) -> ProjectNode {
            let kids = (childrenOf[project.id] ?? [])
                .filter { !ancestors.contains($0.id) }
                .sorted(by: bySavedOrder)
            var nextAncestors = ancestors
            nextAncestors.insert(project.id)
            return ProjectNode(
                project: project,
                depth: depth,
                children: kids.map { node($0, depth: depth + 1, ancestors: nextAncestors) }
            )
        }

        return topLevel.sorted(by: bySavedOrder).map { node($0, depth: 0, ancestors: []) }
    }

    /// Depth-first flattening, matching the tree's visual order.
    static func flatten(_ nodes: [ProjectNode]) -> [ProjectNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }
}
