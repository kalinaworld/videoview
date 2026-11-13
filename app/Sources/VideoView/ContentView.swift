import SwiftUI

@ViewBuilder private func flagFilterLabel(_ filter: FlagFilter) -> some View {
    switch filter {
    case .off:
        Label("Flags", systemImage: "flag")
    case .any:
        Label("Flags", systemImage: "flag.fill").foregroundStyle(.orange)
    case .color(let c):
        Label("Flags", systemImage: "flag.fill").foregroundStyle(c.swiftUIColor)
    }
}

struct ContentView: View {
    @Environment(Library.self) private var libEnv

    var body: some View {
        @Bindable var lib = libEnv
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            DetailView()
        }
        .tint(.steel)
        .searchable(text: $lib.filter, placement: .toolbar, prompt: "Filter clips")
        .toolbar {
            ToolbarItem {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $lib.rowHeight, in: 100...380).frame(width: 90)
                    Image(systemName: "square.grid.2x2").font(.caption).foregroundStyle(.secondary)
                }
                .help("Thumbnail size")
            }
            ToolbarItem {
                Picker("Sort", selection: $lib.sort) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem {
                Picker("Camera", selection: $lib.cameraFilter) {
                    Text("All cameras").tag(String?.none)
                    ForEach(lib.cameras, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem {
                Menu {
                    Button("Show All") { lib.flagFilter = .off }
                    Divider()
                    Button("Any Flag") { lib.flagFilter = .any }
                    ForEach(FlagColor.allCases) { color in
                        Button(color.label) { lib.flagFilter = .color(color) }
                    }
                } label: {
                    flagFilterLabel(lib.flagFilter)
                }
                .help("Filter by flag color")
            }
            ToolbarItem {
                Menu {
                    Button("Show All") { lib.duplicateFilter = .off }
                    Divider()
                    Button("Exact Copies") { lib.duplicateFilter = .exact }
                    Button("Looks Similar") { lib.duplicateFilter = .similar }
                    Button("Exact and Similar") { lib.duplicateFilter = .any }
                } label: {
                    Label("Duplicates", systemImage: lib.duplicateFilter == .off ? "doc.on.doc" : "doc.on.doc.fill")
                        .foregroundStyle(lib.duplicateFilter == .off ? Color.secondary : Color.orange)
                }
                .help("Find clips that exist in several places (exact) or look the same (similar)")
            }
            ToolbarItem {
                Picker("View", selection: $lib.viewMode) {
                    ForEach(ViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Toggle between Minimal and Info view (⌘I)")
                .keyboardShortcut("i", modifiers: .command)
            }
        }
        .sheet(item: $lib.playing) { clip in
            if clip.mediaKind == .image { ImageSheet(clip: clip) }
            else { PlayerSheet(clip: clip) }
        }
        .sheet(item: $lib.spaceSaverTarget) { clip in
            SpaceSaverSheet(clip: clip)
        }
    }
}

struct SidebarView: View {
    @Environment(Library.self) private var lib

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !lib.roots.isEmpty {
                    sectionTitle("Favorites")
                    ForEach(lib.roots, id: \.self) { root in
                        let current = lib.currentDir == root
                        Label((root as NSString).lastPathComponent,
                              systemImage: lib.rootOnline[root] == false ? "externaldrive.badge.xmark" : "star")
                            .foregroundStyle(current ? Color.white : Color.primary)
                            .lineLimit(1)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 5).fill(current ? Color.steel : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { lib.open(root) }
                            .help(root)
                            .folderDrop(root)
                            .contextMenu {
                                Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root) }
                                Button("Remove from Favorites") { lib.removeRoot(root) }
                            }
                    }
                }
                sectionTitle("Folders")
                ForEach(lib.places) { TreeRow(path: $0.path, name: $0.name, icon: $0.icon, depth: 0) }
                ForEach(lib.volumes) { TreeRow(path: $0.path, name: $0.name, icon: $0.icon, depth: 0) }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .background(.regularMaterial)
        .onChange(of: lib.currentDir) { _, d in if let d { lib.revealInTree(d) } }
        .onAppear { if let d = lib.currentDir { lib.revealInTree(d) } }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
    }
}

struct DetailView: View {
    @Environment(Library.self) private var lib
    @FocusState private var gridFocus: Bool
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if let dir = lib.currentDir {
                Header(dir: dir)
                Divider()
                if lib.subdirs.isEmpty && lib.visibleClips.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        GeometryReader { geo in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 20) {
                                    ForEach(tileRows(width: geo.size.width - 32)) { row in
                                        HStack(alignment: .top, spacing: 16) {
                                            ForEach(row.items) { item in
                                                let w = row.height * item.aspect
                                                switch item.kind {
                                                case .folder(let p): FolderCard(path: p, width: w)
                                                case .clip(let c): ClipCard(clip: c, width: w).id(c.path)
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(16)
                            }
                            .onAppear { gridWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, w in gridWidth = w }
                        }
                        .focusable()
                        .focused($gridFocus)
                        .focusEffectDisabled()
                        .onChange(of: lib.selection) { _, _ in gridFocus = true }
                        .onKeyPress("f") {
                            let sel = lib.selectedClips
                            guard !sel.isEmpty else { return .ignored }
                            lib.toggleFlag(sel)
                            return .handled
                        }
                        .onKeyPress(characters: CharacterSet(charactersIn: "a"), phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            lib.selectAll()
                            return .handled
                        }
                        .onKeyPress(.return) {
                            guard let c = lib.selectedClip else { return .ignored }
                            lib.playing = c
                            return .handled
                        }
                        .onKeyPress(.space) {
                            guard let c = lib.selectedClip else { return .ignored }
                            lib.playing = c
                            return .handled
                        }
                        .onKeyPress(.leftArrow) {
                            guard !lib.visibleClips.isEmpty else { return .ignored }
                            moveByClip(-1, proxy: proxy); return .handled
                        }
                        .onKeyPress(.rightArrow) {
                            guard !lib.visibleClips.isEmpty else { return .ignored }
                            moveByClip(1, proxy: proxy); return .handled
                        }
                        .onKeyPress(.upArrow) {
                            guard !lib.visibleClips.isEmpty else { return .ignored }
                            moveByRow(-1, proxy: proxy); return .handled
                        }
                        .onKeyPress(.downArrow) {
                            guard !lib.visibleClips.isEmpty else { return .ignored }
                            moveByRow(1, proxy: proxy); return .handled
                        }
                    }
                }
                Divider()
                StatusBar()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("Add a folder to start browsing").font(.title3)
                    Button("Add Folder…") { lib.pickFolder() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func tileRows(width: Double) -> [TileRow] {
        let items = lib.subdirs.map { TileItem(kind: .folder($0), aspect: 16.0 / 9.0) }
            + lib.visibleClips.map { TileItem(kind: .clip($0), aspect: $0.tileAspect) }
        return justify(items, width: width, target: lib.rowHeight)
    }

    private func moveByClip(_ delta: Int, proxy: ScrollViewProxy) {
        let list = lib.visibleClips
        guard !list.isEmpty else { return }
        let idx = list.firstIndex(where: { lib.selection.contains($0.path) }) ?? (delta > 0 ? -1 : list.count)
        let newIdx = max(0, min(list.count - 1, idx + delta))
        selectAndScroll(list[newIdx], proxy: proxy)
    }

    private func moveByRow(_ delta: Int, proxy: ScrollViewProxy) {
        let rows = tileRows(width: max(gridWidth - 32, 200))
        let clipRows: [[ClipRow]] = rows.compactMap { row in
            let clips = row.items.compactMap { item -> ClipRow? in
                if case .clip(let c) = item.kind { return c } else { return nil }
            }
            return clips.isEmpty ? nil : clips
        }
        guard !clipRows.isEmpty else { return }
        guard let cur = lib.visibleClips.first(where: { lib.selection.contains($0.path) }) else {
            if let first = lib.visibleClips.first { selectAndScroll(first, proxy: proxy) }
            return
        }
        guard let rowIdx = clipRows.firstIndex(where: { $0.contains(where: { $0.path == cur.path }) }),
              let colIdx = clipRows[rowIdx].firstIndex(where: { $0.path == cur.path }) else { return }
        let newRowIdx = max(0, min(clipRows.count - 1, rowIdx + delta))
        guard newRowIdx != rowIdx else { return }
        let targetRow = clipRows[newRowIdx]
        selectAndScroll(targetRow[min(colIdx, targetRow.count - 1)], proxy: proxy)
    }

    private func selectAndScroll(_ clip: ClipRow, proxy: ScrollViewProxy) {
        lib.selection = [clip.path]
        lib.anchor = clip.path
        proxy.scrollTo(clip.path, anchor: .center)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(lib.offline ? "This folder is not reachable and has not been indexed yet." :
                    (lib.scanning ? "Looking for clips…" : "No video clips in this folder."))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Header: View {
    @Environment(Library.self) private var lib
    let dir: String

    /// Clickable path pieces. Starts at Home, a drive, or the top of the disk.
    private var crumbs: [(name: String, path: String)] {
        let home = NSHomeDirectory()
        var base = "/"
        var baseName = "Macintosh HD"
        if dir == home || dir.hasPrefix(home + "/") { base = home; baseName = "Home" }
        else if dir.hasPrefix("/Volumes/") {
            let name = dir.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? ""
            base = "/Volumes/" + name; baseName = name
        }
        var out = [(name: baseName, path: base)]
        let rest = dir.dropFirst(base == "/" ? 0 : base.count)
        var cur = base == "/" ? "" : base
        for part in rest.split(separator: "/") {
            cur += "/" + part
            out.append((name: String(part), path: cur))
        }
        return out
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { lib.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(lib.backStack.isEmpty).help("Back")
            Button { lib.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(lib.forwardStack.isEmpty).help("Forward")
            Button { lib.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!lib.canGoUp).help("Enclosing folder")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                            if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            Button(c.name) { lib.open(c.path) }
                                .buttonStyle(.plain)
                                .font(i == crumbs.count - 1 ? .headline : .callout)
                                .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
                                .folderDrop(c.path)
                                .id(i)
                        }
                    }
                }
                .onAppear { proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
                .onChange(of: dir) { _, _ in proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
            }
            Spacer(minLength: 8)
            Button { lib.promptNewFolder() } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.plain).help("New Folder (⇧⌘N)")
            Button { lib.togglePin(dir) } label: {
                Image(systemName: lib.isPinned(dir) ? "star.fill" : "star")
                    .foregroundStyle(lib.isPinned(dir) ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(lib.isPinned(dir) ? "Remove from Favorites" : "Add this folder to Favorites")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct StatusBar: View {
    @Environment(Library.self) private var lib

    var body: some View {
        HStack(spacing: 12) {
            if lib.offline {
                Label("Folder not reachable. Showing the saved index.", systemImage: "externaldrive.badge.xmark")
                    .foregroundStyle(.orange)
            }
            if lib.progressTotal > 0 && lib.progressDone < lib.progressTotal {
                ProgressView(value: Double(lib.progressDone), total: Double(lib.progressTotal))
                    .frame(width: 140)
                Text("Making thumbnails \(lib.progressDone) of \(lib.progressTotal)")
            }
            if let m = lib.moveStatus {
                ProgressView().controlSize(.small)
                Text(m)
            }
            Spacer()
            if lib.selection.count > 1 { Text("\(lib.selection.count) selected") }
            Text("\(lib.visibleClips.count) clips")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}
