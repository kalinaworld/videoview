import SwiftUI
import AppKit

// Expandable folder tree for the sidebar (like Bridge's Folders panel).

extension Library {
    nonisolated static func childFolders(of path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true && v?.isPackage != true { out.append(u.path) }
        }
        return out.sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    func loadKids(_ path: String, force: Bool = false) {
        if !force && treeKids[path] != nil { return }
        Task.detached(priority: .utility) {
            let kids = Library.childFolders(of: path)
            await MainActor.run { self.treeKids[path] = kids }
        }
    }

    func toggleExpand(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) }
        else { expanded.insert(path); loadKids(path) }
        UserDefaults.standard.set(Array(expanded), forKey: "expandedDirs")
    }

    /// Open every ancestor of `dir` in the tree so the current folder is visible.
    func revealInTree(_ dir: String) {
        var cur = ""
        for part in dir.split(separator: "/") {
            cur += "/" + part
            if cur != dir { expanded.insert(cur); loadKids(cur) }
        }
        expanded.insert("/")
        loadKids("/")
    }
}

struct TreeRow: View {
    @Environment(Library.self) private var lib
    let path: String
    var name: String? = nil
    var icon: String = "folder"
    let depth: Int

    var body: some View {
        let isOpen = lib.expanded.contains(path)
        let kids = lib.treeKids[path]
        let current = lib.currentDir == path
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Group {
                    if kids?.isEmpty == true {
                        Color.clear
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                            .onTapGesture { lib.toggleExpand(path) }
                    }
                }
                .frame(width: 14)
                Image(systemName: icon).foregroundStyle(current ? Color.white : Color.accentColor)
                Text(name ?? (path as NSString).lastPathComponent)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(current ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(current ? Color.accentColor : .clear))
            .contentShape(Rectangle())
            .onTapGesture { lib.open(path) }
            .help(path)
            .folderDrop(path)

            if isOpen, let kids {
                ForEach(kids, id: \.self) { TreeRow(path: $0, depth: depth + 1) }
            }
        }
        .task { if lib.expanded.contains(path) { lib.loadKids(path) } else if depth == 0 { lib.loadKids(path) } }
    }
}
