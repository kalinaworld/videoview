import Foundation
import AppKit
import Observation

struct DirListing {
    struct File { let path: String; let size: Int64; let mtime: Double }
    var files: [File]
    var subdirs: [String]
}

@MainActor @Observable
final class Library {
    @ObservationIgnored let db: Database
    @ObservationIgnored let thumbs = ThumbStore()
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var roots: [String] = []
    var rootOnline: [String: Bool] = [:]
    var currentDir: String?
    var subdirs: [String] = []
    var clips: [ClipRow] = []
    var offline = false
    var scanning = false
    var progressDone = 0
    var progressTotal = 0
    var thumbVersion: [String: Int] = [:]
    var playing: ClipRow?
    var selection: Set<String> = []
    var anchor: String?
    var moveStatus: String?
    @ObservationIgnored var dragPaths: [String] = []
    var sort: SortKey = .name
    var filter = ""
    var cameraFilter: String?
    var flagColors: [String: FlagColor] = [:]
    var flagFilter: FlagFilter = .off
    var flagged: Set<String> { Set(flagColors.keys) }
    var spaceSaverTarget: ClipRow? = nil
    var duplicateCids: Set<String> = []          // exact copies: same content id in more than one place
    var similarMap: [String: [String]] = [:]     // look-alikes (re-encodes, trimmed copies): content id to other content ids
    var duplicateFilter: DuplicateFilter = .off
    @ObservationIgnored private var similarTask: Task<Void, Never>?
    @ObservationIgnored private var similarSignature = -1
    var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .minimal {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var places: [Place] = []
    var expanded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "expandedDirs") ?? [])
    var treeKids: [String: [String]] = [:]
    var rowHeight: Double = UserDefaults.standard.object(forKey: "rowHeight") as? Double ?? 170 {
        didSet { UserDefaults.standard.set(rowHeight, forKey: "rowHeight") }
    }
    var volumes: [Place] = []
    var backStack: [String] = []
    var forwardStack: [String] = []
    let cacheCapBytes = 4 << 30

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoView/index.sqlite").path
        do { db = try Database(path: support) } catch { fatalError("Cannot open the index database: \(error)") }
        roots = db.roots()
        flagColors = db.flagColors()
        duplicateCids = db.duplicateCids()
        places = Self.makePlaces()
        refreshRootStatus()
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshVolumes() }
            }
        }
        // Reopen where you left off. An unreachable folder is fine: it shows the saved index.
        if let last = UserDefaults.standard.string(forKey: "lastDir") { open(last, record: false) }
        else if let first = roots.first { open(first, record: false) }
        else { open(NSHomeDirectory(), record: false) }
    }

    // MARK: places and drives (like the Finder sidebar)

    nonisolated static func makePlaces() -> [Place] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var out = [Place(name: NSUserName(), path: home, icon: "house")]
        let standard: [(String, String, String)] = [
            ("Desktop", "Desktop", "menubar.dock.rectangle"), ("Documents", "Documents", "doc"),
            ("Downloads", "Downloads", "arrow.down.circle"), ("Movies", "Movies", "film"), ("Pictures", "Pictures", "photo"),
        ]
        for (name, sub, icon) in standard where fm.fileExists(atPath: home + "/" + sub) {
            out.append(Place(name: name, path: home + "/" + sub, icon: icon))
        }
        let cloud = home + "/Library/CloudStorage"
        for item in ((try? fm.contentsOfDirectory(atPath: cloud)) ?? []).sorted() where !item.hasPrefix(".") {
            var name = item
            if item.hasPrefix("Dropbox") { name = "Dropbox" }
            else if item.hasPrefix("GoogleDrive") { name = "Google Drive" }
            else if item.hasPrefix("OneDrive") { name = "OneDrive" }
            out.append(Place(name: name, path: cloud + "/" + item, icon: "cloud"))
        }
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if fm.fileExists(atPath: icloud) { out.append(Place(name: "iCloud Drive", path: icloud, icon: "icloud")) }
        return out
    }

    func refreshVolumes() {
        Task.detached(priority: .utility) {
            let keys: [URLResourceKey] = [.volumeIsLocalKey]
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            var list: [Place] = [Place(name: "Macintosh HD", path: "/", icon: "internaldrive")]
            for u in urls where u.path.hasPrefix("/Volumes/") {
                let local = (try? u.resourceValues(forKeys: Set(keys)))?.volumeIsLocal ?? true
                list.append(Place(name: u.lastPathComponent, path: u.path, icon: local ? "externaldrive" : "network"))
            }
            let result = list
            await MainActor.run { [weak self] in self?.volumes = result }
        }
    }

    // MARK: derived

    var visibleClips: [ClipRow] {
        var list = clips
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) || $0.camera.lowercased().contains(q) } }
        switch flagFilter {
        case .off: break
        case .any: list = list.filter { flagColors[$0.cid] != nil }
        case .color(let c): list = list.filter { flagColors[$0.cid] == c }
        }
        if let cam = cameraFilter { list = list.filter { $0.camera == cam } }
        switch duplicateFilter {
        case .off: break
        case .exact: list = list.filter { duplicateCids.contains($0.cid) }
        case .similar: list = list.filter { similarMap[$0.cid] != nil }
        case .any: list = list.filter { duplicateCids.contains($0.cid) || similarMap[$0.cid] != nil }
        }
        switch sort {
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: list.sort { $0.sortDate > $1.sortDate }
        case .duration: list.sort { $0.duration > $1.duration }
        case .size: list.sort { $0.size > $1.size }
        case .camera:
            list.sort {
                if $0.camera != $1.camera {
                    if $0.camera.isEmpty { return false }      // unknown cameras last
                    if $1.camera.isEmpty { return true }
                    return $0.camera.localizedStandardCompare($1.camera) == .orderedAscending
                }
                return $0.sortDate < $1.sortDate
            }
        }
        return list
    }

    var cameras: [String] {
        Array(Set(clips.map { $0.camera }.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func toggleFlag(_ cid: String) {
        if flagColors[cid] != nil {
            flagColors.removeValue(forKey: cid)
            db.setFlag(cid, nil)
        } else {
            flagColors[cid] = .orange
            db.setFlag(cid, .orange)
        }
    }

    func setFlagColor(_ cid: String, _ color: FlagColor) {
        flagColors[cid] = color
        db.setFlag(cid, color)
    }

    var selectedClip: ClipRow? { clips.first { selection.contains($0.path) } }

    var canGoUp: Bool { (currentDir ?? "/") != "/" }

    func isPinned(_ dir: String) -> Bool { roots.contains(dir) }

    func togglePin(_ dir: String) {
        if isPinned(dir) { db.removeRoot(dir) } else { db.addRoot(dir) }
        roots = db.roots()
        refreshRootStatus()
    }

    /// Asks for a path (Finder's Go to Folder). Accepts ~ and drag-and-dropped paths.
    func goToFolder() {
        let a = NSAlert()
        a.messageText = "Go to Folder"
        a.informativeText = "Type or paste a folder path."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = "/Volumes/WytheNAS/Video"
        a.accessoryView = field
        a.addButton(withTitle: "Go")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        var p = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        p = (p as NSString).expandingTildeInPath
        guard !p.isEmpty else { return }
        open(p)
    }

    // MARK: roots

    func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Add"
        p.message = "Choose folders with video clips. Nothing is changed or copied."
        p.begin { [weak self] resp in
            guard resp == .OK else { return }
            let paths = p.urls.map { $0.path }
            Task { @MainActor in
                for path in paths { self?.addRoot(path) }
            }
        }
    }

    func addRoot(_ path: String) {
        db.addRoot(path)
        roots = db.roots()
        refreshRootStatus()
        open(path)
    }

    func removeRoot(_ path: String) {
        db.removeRoot(path)
        roots = db.roots()
    }

    func refreshRootStatus() {
        let list = roots
        Task.detached(priority: .utility) {
            var res: [String: Bool] = [:]
            for r in list { res[r] = FileManager.default.fileExists(atPath: r) }
            let snapshot = res
            await MainActor.run { [weak self] in self?.rootOnline = snapshot }
        }
    }

    // MARK: browsing (lazy: only the folder you open gets scanned)

    func open(_ dir: String, record: Bool = true) {
        scanTask?.cancel()
        if record, let cur = currentDir, cur != dir {
            backStack.append(cur)
            forwardStack = []
        }
        UserDefaults.standard.set(dir, forKey: "lastDir")
        currentDir = dir
        selection = []
        cameraFilter = nil
        clips = db.clips(inDir: dir)          // cached index shows immediately, even if the NAS is away
        subdirs = db.subdirs(of: dir)
        progressDone = 0; progressTotal = 0
        scanTask = Task { await scan(dir) }
    }

    func goUp() {
        guard canGoUp, let c = currentDir else { return }
        open((c as NSString).deletingLastPathComponent)
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        if let cur = currentDir { forwardStack.append(cur) }
        open(prev, record: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let cur = currentDir { backStack.append(cur) }
        open(next, record: false)
    }

    nonisolated static func listDirectory(_ dir: String) -> DirListing? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var files: [DirListing.File] = []
        var subdirs: [String] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if v?.isPackage != true { subdirs.append(u.path) }   // skips .app, Photos and Final Cut libraries
            } else if Indexer.allExts.contains(u.pathExtension.lowercased()) {
                files.append(.init(path: u.path, size: Int64(v?.fileSize ?? 0),
                                   mtime: v?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        subdirs.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return DirListing(files: files, subdirs: subdirs)
    }

    nonisolated static func reconcile(_ dir: String, _ l: DirListing, _ db: Database) -> [ClipRow] {
        let existing = Dictionary(db.clips(inDir: dir).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [ClipRow] = []
        for f in l.files {
            if Task.isCancelled { return out }
            if let e = existing[f.path], e.size == f.size, abs(e.mtime - f.mtime) < 1 { out.append(e); continue }
            var row = ClipRow(path: f.path, cid: Indexer.contentID(path: f.path, size: f.size), dir: dir,
                              name: (f.path as NSString).lastPathComponent, size: f.size, mtime: f.mtime)
            if let known = db.readyClip(cid: row.cid) {
                row.duration = known.duration; row.width = known.width; row.height = known.height
                row.fps = known.fps; row.codec = known.codec; row.created = known.created
                row.camera = known.camera; row.status = 1
            }
            db.upsertClip(row)
            out.append(row)
        }
        db.deleteClips(inDir: dir, keeping: Set(out.map { $0.path }))
        for s in l.subdirs { db.upsertDir(s, parent: dir) }
        db.deleteDirs(parent: dir, keeping: Set(l.subdirs))
        return out
    }

    private func scan(_ dir: String) async {
        scanning = true
        defer { if currentDir == dir { scanning = false } }
        let db = self.db, thumbs = self.thumbs

        let listing = await Task.detached(priority: .utility) { Library.listDirectory(dir) }.value
        guard !Task.isCancelled, currentDir == dir else { return }
        guard let listing else {
            if !FileManager.default.fileExists(atPath: dir) {
                // Folder was deleted: purge the DB, clear the view, and go up.
                db.deleteClips(inDir: dir, keeping: [])
                clips = []
                subdirs = []
                treeKids.removeValue(forKey: dir)
                let parent = (dir as NSString).deletingLastPathComponent
                loadKids(parent, force: true)
                open(parent)
            } else {
                offline = true
            }
            return
        }
        offline = false

        let rows = await Task.detached(priority: .utility) { Library.reconcile(dir, listing, db) }.value
        guard !Task.isCancelled, currentDir == dir else { return }
        clips = rows
        subdirs = listing.subdirs
        // Keep the sidebar tree in sync with what the filesystem actually has.
        treeKids[dir] = listing.subdirs
        let parentDir = (dir as NSString).deletingLastPathComponent
        if treeKids[parentDir] != nil { loadKids(parentDir, force: true) }

        // Audio has no thumb pack; only check thumbs.exists for video and image.
        let todo = rows.filter { $0.status != 1 || ($0.mediaKind != .audio && !thumbs.exists($0.cid)) }
        progressTotal = todo.count
        progressDone = 0
        guard !todo.isEmpty else {
            duplicateCids = db.duplicateCids()
            refreshSimilar()
            return
        }

        let work: @Sendable (ClipRow) async -> ClipRow = { r in
            let done = await Indexer.process(r, thumbs: thumbs)
            if done.status != 0 { db.upsertClip(done) }
            return done
        }
        await withTaskGroup(of: ClipRow.self) { group in
            var it = todo.makeIterator()
            for _ in 0..<3 {
                if let r = it.next() { group.addTask(priority: .utility) { await work(r) } }
            }
            while let done = await group.next() {
                if Task.isCancelled || currentDir != dir { group.cancelAll(); break }
                apply(done)
                if let r = it.next() { group.addTask(priority: .utility) { await work(r) } }
            }
        }
        if currentDir == dir {
            Task.detached(priority: .background) { thumbs.trim(toBytes: 4 << 30) }
            duplicateCids = db.duplicateCids()
            refreshSimilar()
        }
    }

    /// Fingerprints any clip that has cached frames but no fingerprint yet, then looks for look-alikes across the whole
    /// index (not only this folder). Runs in the background and only reads the cache, never a clip.
    func refreshSimilar() {
        similarTask?.cancel()
        let db = self.db, thumbs = self.thumbs
        let known = similarSignature
        similarTask = Task.detached(priority: .background) { [weak self] in
            var added = 0
            for cid in db.cidsNeedingFingerprint() {
                if Task.isCancelled { return }
                guard let pack = thumbs.pack(cid) else { continue }
                db.setFingerprint(cid, Fingerprint.encode(Fingerprint.hashes(from: pack)))
                added += 1
            }
            let prints = db.clipPrints()
            if added == 0 && prints.count == known { return }      // nothing changed since the last pass
            guard let map = Similarity.findSimilar(prints), !Task.isCancelled else { return }
            let count = prints.count
            await MainActor.run { [weak self] in
                self?.similarMap = map
                self?.similarSignature = count
            }
        }
    }

    private func apply(_ row: ClipRow) {
        progressDone += 1
        if let i = clips.firstIndex(where: { $0.path == row.path }) { clips[i] = row }
        thumbVersion[row.cid, default: 0] += 1
    }

    func rebuildCache() {
        scanTask?.cancel()
        thumbs.clearAll()
        db.resetStatuses()
        thumbVersion = [:]
        if let c = currentDir { open(c) }
    }

    // MARK: delete (always asks first, goes to the Trash so it can be put back)

    nonisolated private static func removeFile(_ url: URL, permanent: Bool) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                if permanent { try FileManager.default.removeItem(at: url) }
                else { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                return nil
            } catch { return error.localizedDescription }
        }.value
    }

    private func forget(_ clip: ClipRow) {
        db.removeClip(path: clip.path)
        clips.removeAll { $0.path == clip.path }
        selection.remove(clip.path)
        duplicateCids = db.duplicateCids()
        refreshSimilar()
    }

    /// Asks, then moves the file to the Trash. If the volume has no Trash (a NAS often does not), asks once more
    /// before deleting permanently. Returns true if the file is gone.
    func confirmAndTrash(_ clip: ClipRow, extra: String = "") async -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Move “\(clip.name)” to the Trash?"
        a.informativeText = "\(formatSize(clip.size)). \(extra)You can put it back from the Trash until you empty it."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        guard FileManager.default.fileExists(atPath: clip.path) else { forget(clip); return true }
        guard let err = await Self.removeFile(clip.url, permanent: false) else { forget(clip); return true }

        let b = NSAlert()
        b.alertStyle = .critical
        b.messageText = "Could not move it to the Trash"
        b.informativeText = "\(err)\n\nNetwork drives often have no Trash. Delete “\(clip.name)” permanently instead? This cannot be undone."
        b.addButton(withTitle: "Delete Permanently")
        b.addButton(withTitle: "Cancel")
        guard b.runModal() == .alertFirstButtonReturn else { return false }
        if let err2 = await Self.removeFile(clip.url, permanent: true) {
            let c = NSAlert()
            c.messageText = "Could not delete the file"
            c.informativeText = err2
            c.runModal()
            return false
        }
        forget(clip)
        return true
    }

    func reveal(_ clip: ClipRow) {
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }
}
