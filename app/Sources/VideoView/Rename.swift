import SwiftUI
import AppKit

extension Library {
    /// Rename a clip (and its sidecar files) in place. The extension stays as it is.
    func promptRename(_ clip: ClipRow) {
        let src = clip.url
        let ext = src.pathExtension
        let oldStem = src.deletingPathExtension().lastPathComponent

        let a = NSAlert()
        a.messageText = "Rename Clip"
        a.informativeText = "The extension (.\(ext)) stays the same. Matching sidecar files are renamed too."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = oldStem
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let newStem = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if newStem == oldStem { return }
        guard !newStem.isEmpty, !newStem.contains("/"), !newStem.contains(":"), !newStem.hasPrefix(".") else {
            showError("That name can't be used.", "Names can't be empty, start with a dot, or contain / or :")
            return
        }

        let dir = src.deletingLastPathComponent()
        let fm = FileManager.default
        func target(_ u: URL) -> URL {
            // keep whatever follows the stem (Sony's "M01"), swap the stem itself
            let base = u.deletingPathExtension().lastPathComponent
            let suffix = String(base.dropFirst(oldStem.count))
            return dir.appendingPathComponent(newStem + suffix).appendingPathExtension(u.pathExtension)
        }
        var pairs: [(URL, URL)] = [(src, target(src))]
        for s in Library.sidecars(of: src) { pairs.append((s, target(s))) }

        for (from, to) in pairs {
            let sameFile = from.path.lowercased() == to.path.lowercased()   // case-only rename
            if !sameFile && fm.fileExists(atPath: to.path) {
                showError("“\(to.lastPathComponent)” already exists.", "Pick a different name.")
                return
            }
        }

        var done: [(URL, URL)] = []
        do {
            for (from, to) in pairs {
                try fm.moveItem(at: from, to: to)
                done.append((from, to))
            }
        } catch {
            for (from, to) in done.reversed() { try? fm.moveItem(at: to, to: from) }   // undo
            showError("Could not rename.", error.localizedDescription)
            return
        }

        // Flags and thumbnails are keyed by content, so they follow the file. Just refresh the row.
        db.removeClip(path: clip.path)
        selection.remove(clip.path)
        let newPath = pairs[0].1.path
        selection.insert(newPath)
        if let d = currentDir { open(d, record: false) }
        moveStatus = "Renamed to “\(newPath.split(separator: "/").last.map(String.init) ?? newPath)”"
    }
}
