import Foundation
import AppKit
import CryptoKit
import SwiftUI

/// Moving clips between folders and making new folders.
/// Same-drive moves are instant renames. Moves between drives copy, check the copy byte for byte,
/// and only then remove the original. Sidecar files (Sony XML, SRT, THM, LRF...) travel with their clip.
struct MoveItem {
    let clip: ClipRow
    let files: [URL]          // the clip first, then its sidecars
}

struct MovePlan {
    var items: [MoveItem] = []
    var skipped: [String] = []
    var crossVolume = false
}

extension Library {

    // MARK: selection

    var selectedClips: [ClipRow] { visibleClips.filter { selection.contains($0.path) } }

    func targets(for clip: ClipRow) -> [ClipRow] { selection.contains(clip.path) ? selectedClips : [clip] }

    func selectAll() { selection = Set(visibleClips.map { $0.path }) }

    func click(_ clip: ClipRow, command: Bool, shift: Bool) {
        let list = visibleClips
        if shift, let a = anchor, let i = list.firstIndex(where: { $0.path == a }),
           let j = list.firstIndex(where: { $0.path == clip.path }) {
            selection = Set(list[min(i, j)...max(i, j)].map { $0.path })
        } else if command {
            if selection.contains(clip.path) { selection.remove(clip.path) } else { selection.insert(clip.path) }
            anchor = clip.path
        } else {
            selection = [clip.path]
            anchor = clip.path
        }
    }

    func toggleFlag(_ list: [ClipRow]) {
        guard !list.isEmpty else { return }
        let allFlagged = list.allSatisfy { flagColors[$0.cid] != nil }
        for c in list {
            if allFlagged {
                flagColors.removeValue(forKey: c.cid)
                db.setFlag(c.cid, nil)
            } else if flagColors[c.cid] == nil {
                flagColors[c.cid] = .orange
                db.setFlag(c.cid, .orange)
            }
        }
    }

    func setFlag(_ list: [ClipRow], color: FlagColor) {
        for c in list {
            flagColors[c.cid] = color
            db.setFlag(c.cid, color)
        }
    }

    func removeFlag(_ list: [ClipRow]) {
        for c in list {
            flagColors.removeValue(forKey: c.cid)
            db.setFlag(c.cid, nil)
        }
    }

    // MARK: drag and drop

    func beginDrag(_ clip: ClipRow) {
        dragPaths = targets(for: clip).map { $0.path }
    }

    /// Handles clips dropped on a folder. Clips dragged from this window use the whole selection.
    /// Video files dragged in from the Finder are moved too.
    func handleDrop(_ providers: [NSItemProvider], to dest: String) -> Bool {
        let lock = NSLock()
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { u, _ in
                if let u { lock.lock(); urls.append(u); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let internalSet = Set(self.dragPaths)
                var rows: [ClipRow] = []
                if !urls.isEmpty, urls.allSatisfy({ internalSet.contains($0.path) }) {
                    rows = self.clips.filter { internalSet.contains($0.path) }
                } else {
                    for u in urls where Indexer.videoExts.contains(u.pathExtension.lowercased()) {
                        let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        rows.append(ClipRow(path: u.path, cid: "", dir: u.deletingLastPathComponent().path, name: u.lastPathComponent,
                                            size: Int64(v?.fileSize ?? 0), mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0))
                    }
                }
                self.dragPaths = []
                await self.moveClips(rows, to: dest)
            }
        }
        return true
    }

    // MARK: new folder

    func promptNewFolder(moving: [ClipRow] = []) {
        guard let dir = currentDir else { return }
        let a = NSAlert()
        a.messageText = moving.isEmpty ? "New Folder" : "New Folder with \(moving.count) clip\(moving.count == 1 ? "" : "s")"
        a.informativeText = "It will be made inside “\((dir as NSString).lastPathComponent)”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = "New Folder"
        a.accessoryView = field
        a.addButton(withTitle: "Create")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            showError("That name can't be used.", "Folder names can't be empty, start with a dot, or contain / or :")
            return
        }
        let path = (dir as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: path) {
            showError("“\(name)” already exists.", "Pick a different name.")
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            showError("Could not make the folder.", error.localizedDescription)
            return
        }
        db.upsertDir(path, parent: dir)
        subdirs.append(path)
        subdirs.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        if !moving.isEmpty { Task { await moveClips(moving, to: path) } }
    }

    func chooseDestinationAndMove(_ list: [ClipRow]) {
        guard !list.isEmpty else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true          // the panel has its own New Folder button
        p.allowsMultipleSelection = false
        p.prompt = "Move Here"
        p.message = "Choose the folder to move \(list.count) clip\(list.count == 1 ? "" : "s") into."
        if let c = currentDir { p.directoryURL = URL(fileURLWithPath: c) }
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await moveClips(list, to: url.path) }
    }

    // MARK: moving

    nonisolated static func sidecars(of video: URL) -> [URL] {
        let dir = video.deletingLastPathComponent()
        let stem = video.deletingPathExtension().lastPathComponent.lowercased()
        let vext = video.pathExtension.lowercased()
        let exts: Set<String> = ["xml", "srt", "thm", "lrf", "lrv", "xmp"]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { u in
            let base = u.deletingPathExtension().lastPathComponent.lowercased()
            let ext = u.pathExtension.lowercased()
            if ext == vext { return false }
            return (base == stem && exts.contains(ext)) || (base == stem + "m01" && ext == "xml")   // Sony: C0004M01.XML
        }
    }

    nonisolated static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = (try? a.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        let vb = (try? b.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        guard let va, let vb else { return false }
        return va.isEqual(vb)
    }

    nonisolated static func planMoves(_ clips: [ClipRow], dest: URL) -> MovePlan {
        var plan = MovePlan()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue else {
            plan.skipped.append("The destination folder is not reachable.")
            return plan
        }
        for c in clips {
            let files = [c.url] + sidecars(of: c.url)
            if let clash = files.first(where: { fm.fileExists(atPath: dest.appendingPathComponent($0.lastPathComponent).path) }) {
                plan.skipped.append("\(c.name): “\(clash.lastPathComponent)” already exists there")
                continue
            }
            if !fm.fileExists(atPath: c.path) {
                plan.skipped.append("\(c.name): the file is no longer there")
                continue
            }
            if !sameVolume(c.url, dest) { plan.crossVolume = true }
            plan.items.append(MoveItem(clip: c, files: files))
        }
        return plan
    }

    nonisolated static func fileDigest(_ url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = SHA256()
        while let d = try fh.read(upToCount: 8 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copy to a temporary name, compare both files byte for byte (SHA-256), rename, then remove the original.
    nonisolated static func copyVerifiedThenRemove(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let part = dst.appendingPathExtension("vvpart")
        try? fm.removeItem(at: part)
        try fm.copyItem(at: src, to: part)           // keeps dates and Finder metadata
        let a = try fileDigest(src), b = try fileDigest(part)
        let sizeA = (try fm.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? -1
        let sizeB = (try fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value ?? -2
        guard a == b, sizeA == sizeB else {
            try? fm.removeItem(at: part)
            throw NSError(domain: "VideoView", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The copy did not match the original, so nothing was removed."])
        }
        try fm.moveItem(at: part, to: dst)
        do { try fm.trashItem(at: src, resultingItemURL: nil) }      // recoverable if the drive has a Trash
        catch { try fm.removeItem(at: src) }                         // the copy is verified, so this is safe
    }

    nonisolated static func moveOne(_ item: MoveItem, to dest: URL) -> String? {
        let fm = FileManager.default
        for (i, f) in item.files.enumerated() {
            let dst = dest.appendingPathComponent(f.lastPathComponent)
            do {
                if sameVolume(f, dest) { try fm.moveItem(at: f, to: dst) }
                else { try copyVerifiedThenRemove(f, to: dst) }
            } catch {
                return i == 0 ? error.localizedDescription
                              : "moved, but the sidecar “\(f.lastPathComponent)” could not be: \(error.localizedDescription)"
            }
        }
        return nil
    }

    func moveClips(_ input: [ClipRow], to destDir: String) async {
        let list = input.filter { $0.dir != destDir }
        guard !list.isEmpty else { return }
        let dest = URL(fileURLWithPath: destDir, isDirectory: true)
        let destName = dest.lastPathComponent

        moveStatus = "Checking…"
        let plan = await Task.detached(priority: .userInitiated) { Library.planMoves(list, dest: dest) }.value
        if plan.items.isEmpty { moveStatus = nil; report(moved: 0, destName: destName, problems: plan.skipped); return }

        if plan.crossVolume {
            let a = NSAlert()
            a.messageText = "Move to another drive?"
            a.informativeText = "Each clip is copied, checked byte for byte against the original, and only then removed from here. Big clips take a while."
            a.addButton(withTitle: "Move")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { moveStatus = nil; return }
        }

        var problems = plan.skipped
        var movedPaths: [String] = []
        for (i, item) in plan.items.enumerated() {
            moveStatus = (plan.crossVolume ? "Copying and checking " : "Moving ") + "\(item.clip.name) (\(i + 1) of \(plan.items.count))…"
            let err = await Task.detached(priority: .userInitiated) { Library.moveOne(item, to: dest) }.value
            if let err {
                problems.append("\(item.clip.name): \(err)")
                if !FileManager.default.fileExists(atPath: item.clip.path) { movedPaths.append(item.clip.path) }
            } else {
                movedPaths.append(item.clip.path)
            }
        }
        for p in movedPaths { db.removeClip(path: p) }
        clips.removeAll { movedPaths.contains($0.path) }
        selection.subtract(movedPaths)
        if currentDir == destDir { open(destDir, record: false) }

        let msg = movedPaths.isEmpty ? nil
            : "Moved \(movedPaths.count) clip\(movedPaths.count == 1 ? "" : "s") to “\(destName)”"
        moveStatus = msg
        if let msg { Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if moveStatus == msg { moveStatus = nil } } }
        report(moved: movedPaths.count, destName: destName, problems: problems)
    }

    private func report(moved: Int, destName: String, problems: [String]) {
        guard !problems.isEmpty else { return }
        showError(moved > 0 ? "Moved \(moved), but some were left alone." : "Nothing was moved.",
                  problems.prefix(8).joined(separator: "\n") + (problems.count > 8 ? "\n…and \(problems.count - 8) more" : ""))
    }

    func showError(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        a.informativeText = detail
        a.runModal()
    }
}


/// Makes a view accept clips dropped on it (folder cards, sidebar rows, path pieces).
struct FolderDrop: ViewModifier {
    @Environment(Library.self) private var lib
    let dest: String
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in lib.handleDrop(providers, to: dest) }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func folderDrop(_ dest: String) -> some View { modifier(FolderDrop(dest: dest)) }
}
