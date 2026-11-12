import SwiftUI

struct FolderCard: View {
    @Environment(Library.self) private var lib
    let path: String
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: "folder.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            Text((path as NSString).lastPathComponent).font(.callout).lineLimit(1)
        }
        .frame(width: width, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { lib.open(path) }
        .folderDrop(path)
    }
}

struct ClipCard: View {
    @Environment(Library.self) private var lib
    let clip: ClipRow
    let width: CGFloat
    @State private var poster: NSImage?
    @State private var hoverFraction: Double?

    private var selected: Bool { lib.selection.contains(clip.path) }
    private var version: Int { lib.thumbVersion[clip.cid] ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Color.black
                    if let img = displayImage {
                        Image(nsImage: img).resizable().scaledToFit()
                    } else if clip.status == 2 {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if let f = hoverFraction {
                        // scrub position bar
                        GeometryReader { g in
                            Rectangle().fill(Color.accentColor).frame(width: g.size.width * f, height: 3)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let fc = lib.flagColors[clip.cid] {
                        Image(systemName: "flag.fill").foregroundStyle(fc.swiftUIColor)
                            .padding(5)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if clip.duration > 0 {
                        Text(hoverFraction.map { formatDuration($0 * clip.duration) } ?? formatDuration(clip.duration))
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hoverFraction = min(max(p.x / max(geo.size.width, 1), 0), 0.9999)
                    case .ended: hoverFraction = nil
                    }
                }
            }
            .aspectRatio(mediaAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))

            Text(clip.name).font(.callout).lineLimit(1).truncationMode(.middle)
            if width >= 150 { Text(infoLine).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if !clip.camera.isEmpty && width >= 150 {
                Text(clip.camera).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if width >= 150, let savings = clip.savingsLabel {
                Text(savings).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .task(id: version) { poster = lib.thumbs.poster(clip.cid) }
        .onTapGesture(count: 2) { lib.playing = clip }
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            lib.click(clip, command: mods.contains(.command), shift: mods.contains(.shift))
        }
        .onDrag {
            lib.beginDrag(clip)
            return NSItemProvider(object: clip.url as NSURL)
        }
        .contextMenu {
            Button("Play") { lib.playing = clip }
            let group = lib.targets(for: clip)
            let n = group.count
            let allFlagged = group.allSatisfy { lib.flagColors[$0.cid] != nil }
            Menu(allFlagged ? "Change Flag Color" : "Flag") {
                ForEach(FlagColor.allCases) { color in
                    Button("Flag \(color.label)") { lib.setFlag(group, color: color) }
                }
                if allFlagged { Divider(); Button("Remove Flag") { lib.removeFlag(group) } }
            }
            Button("Space Saver…") { lib.spaceSaverTarget = clip }
            Divider()
            Button(n > 1 ? "Move \(n) Clips to…" : "Move to…") { lib.chooseDestinationAndMove(group) }
            Button(n > 1 ? "New Folder with \(n) Clips…" : "New Folder with This Clip…") { lib.promptNewFolder(moving: group) }
            if n == 1 { Button("Rename…") { lib.promptRename(clip) } }
            Button("Reveal in Finder") { lib.reveal(clip) }
            Divider()
            Button("Move to Trash…") { Task { _ = await lib.confirmAndTrash(clip) } }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clip.path, forType: .string)
            }
        }
    }

    private var mediaAspect: Double { clip.tileAspect }

    private var displayImage: NSImage? {
        if let f = hoverFraction, let p = lib.thumbs.pack(clip.cid) {
            return lib.thumbs.image(clip.cid, min(Int(f * Double(p.count)), p.count - 1)) ?? poster
        }
        return poster
    }

    private var infoLine: String {
        var parts: [String] = []
        let shot = formatShotDate(clip.sortDate)
        if !shot.isEmpty { parts.append(shot) }
        let res = resolutionLabel(clip.width, clip.height)
        if !res.isEmpty { parts.append(res) }
        if clip.fps > 0 { parts.append(String(format: "%g fps", (clip.fps * 100).rounded() / 100)) }
        parts.append(formatSize(clip.size))
        if let mbps = clip.bitrateMbps { parts.append(formatBitrate(mbps)) }
        return parts.joined(separator: "  ·  ")
    }
}
