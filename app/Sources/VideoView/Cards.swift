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
        .contextMenu {
            Button("Open") { lib.open(path) }
            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
        }
    }
}

struct ClipCard: View {
    @Environment(Library.self) private var lib
    let clip: ClipRow
    let width: CGFloat
    @State private var poster: NSImage?
    @State private var hoverFraction: Double?
    @State private var hovering = false

    private var selected: Bool { lib.selection.contains(clip.path) }
    private var version: Int { lib.thumbVersion[clip.cid] ?? 0 }
    private var isMinimal: Bool { lib.viewMode == .minimal }

    var body: some View {
        VStack(alignment: .leading, spacing: isMinimal ? 0 : 5) {
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
                        GeometryReader { g in
                            Rectangle().fill(Color.steel).frame(width: g.size.width * f, height: 3)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    // Minimal mode: filename fades in on hover
                    if isMinimal && hovering {
                        LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                        VStack {
                            Spacer()
                            Text(clip.name)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 6).padding(.bottom, 7)
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
                .overlay(alignment: .topLeading) {
                    // Info mode: resolution badge (sits below the flag if both present)
                    if !isMinimal, let badge = resBadge {
                        let hasFlag = lib.flagColors[clip.cid] != nil
                        Text(badge.label)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(badge.color, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(badge.textColor)
                            .padding(.leading, 5)
                            .padding(.top, hasFlag ? 30 : 5)
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
                    case .active(let p):
                        hoverFraction = min(max(p.x / max(geo.size.width, 1), 0), 0.9999)
                        hovering = true
                    case .ended:
                        hoverFraction = nil
                        hovering = false
                    }
                }
            }
            .aspectRatio(mediaAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.steel : .clear, lineWidth: 3))

            if !isMinimal {
                Text(clip.name).font(.callout).lineLimit(1).truncationMode(.middle)
                if width >= 150 {
                    HStack(spacing: 6) {
                        if let mbps = clip.bitrateMbps {
                            Text(formatBitrate(mbps))
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(bitrateColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 20))
                                .foregroundStyle(bitrateColor)
                        }
                        Text(formatSize(clip.size))
                            .font(.caption).foregroundStyle(.secondary)
                        if !clip.camera.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.tertiary)
                            Text(clip.camera).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if clip.created > 0 {
                            Text("·").font(.caption).foregroundStyle(.tertiary)
                            Text(formatShotDate(clip.created)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if width >= 150, let savings = clip.savingsLabel {
                    Text(savings).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
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

    private struct ResBadge { let label: String; let color: Color; let textColor: Color }

    private var resBadge: ResBadge? {
        let long = max(clip.width, clip.height)
        guard long > 0 else { return nil }
        switch long {
        case 5000...: return ResBadge(label: "6K", color: .steel, textColor: Color(white: 0.92))
        case 3600...: return ResBadge(label: "4K", color: .white.opacity(0.18), textColor: .white)
        case 1800...: return ResBadge(label: "1080p", color: .white.opacity(0.08), textColor: .secondary)
        case 1...:    return ResBadge(label: resolutionLabel(clip.width, clip.height), color: .white.opacity(0.08), textColor: .secondary)
        default:      return nil
        }
    }

    private var bitrateColor: Color {
        guard let mbps = clip.bitrateMbps else { return .secondary }
        if mbps > 300 { return .steel }
        if mbps > 80  { return Color(red: 0.8, green: 0.65, blue: 0.2) }
        return .secondary
    }
}
