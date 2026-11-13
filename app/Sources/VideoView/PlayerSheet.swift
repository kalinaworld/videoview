import SwiftUI
import AVKit
import Observation

enum TrimState {
    case idle
    case running
    case done(path: String, ok: Bool, lines: [String])
    case failed(String)
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00.00" }
    let m = Int(s) / 60
    let rest = s - Double(m * 60)
    return String(format: "%d:%05.2f", m, rest)
}

@MainActor @Observable
final class PlayerController {
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeToken: Any?
    @ObservationIgnored var onFlag: (() -> Void)?
    private let rates: [Float] = [1, 2, 4, 8]

    var speedStep = 0          // -4...4, 0 = stopped
    var now = 0.0
    var markIn: Double?
    var markOut: Double?
    var trim: TrimState = .idle

    func load(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.04, preferredTimescale: 600),
                                                   queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.now = t.seconds }
        }
    }

    func teardown() {
        if let t = timeToken { player.removeTimeObserver(t); timeToken = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func apply() {
        if speedStep == 0 { player.pause(); return }
        let r = rates[abs(speedStep) - 1]
        player.rate = speedStep > 0 ? r : -r
    }

    func forward() { speedStep = speedStep > 0 ? min(speedStep + 1, 4) : 1; apply() }
    func backward() { speedStep = speedStep < 0 ? max(speedStep - 1, -4) : -1; apply() }
    func stop() { speedStep = 0; apply() }

    func toggle() {
        if player.rate != 0 { speedStep = 0; player.pause() } else { speedStep = 1; player.rate = 1 }
    }

    func step(_ n: Int) {
        speedStep = 0
        player.pause()
        player.currentItem?.step(byCount: n)
    }

    func seek(_ seconds: Double) {
        now = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: marks

    func setIn(_ duration: Double) {
        markIn = now
        if let o = markOut, o <= now + 0.05 { markOut = nil }
    }

    func setOut(_ duration: Double) {
        markOut = min(now, duration)
        if let i = markIn, i >= (markOut ?? 0) - 0.05 { markIn = nil }
    }

    func clearMarks() { markIn = nil; markOut = nil }

    func range(_ duration: Double) -> (Double, Double) {
        (markIn ?? 0, markOut ?? duration)
    }

    func hasRange(_ duration: Double) -> Bool {
        let (a, b) = range(duration)
        return b - a >= 0.1 && (markIn != nil || markOut != nil)
    }

    // MARK: lossless trim (container level, nothing is re-encoded, the original is never touched)

    nonisolated static func uniqueOutput(for src: String) -> String {
        let u = URL(fileURLWithPath: src)
        let dir = u.deletingLastPathComponent()
        let stem = u.deletingPathExtension().lastPathComponent
        let ext = u.pathExtension
        var n = 1
        func name(_ n: Int) -> String { n == 1 ? "\(stem)_trim.\(ext)" : "\(stem)_trim_\(n).\(ext)" }
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name(n)).path)
                || FileManager.default.fileExists(atPath: dir.appendingPathComponent(name(n)).path + ".partial") { n += 1 }
        return dir.appendingPathComponent(name(n)).path
    }

    func saveTrim(clip: ClipRow, completion: @escaping @MainActor () -> Void) {
        if case .running = trim { return }
        let (a, b) = range(clip.duration)
        guard hasRange(clip.duration) else { return }
        trim = .running
        player.pause(); speedStep = 0
        let src = clip.path
        Task.detached(priority: .userInitiated) {
            var lines: [String] = []
            let out = PlayerController.uniqueOutput(for: src)
            var state: TrimState
            do {
                let r = try containerTrim(src: src, out: out, from: a, to: b, cutStart: 0, cutEnd: 0, dry: false,
                                          log: { lines.append($0) })
                var ok = r.ok
                if r.ok {
                    let apple = await appleCheck(path: r.outPath, srcPath: src, expected: r.expectedSeconds,
                                                 log: { lines.append($0) })
                    ok = ok && apple
                }
                lines.append(ok ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED")
                state = .done(path: r.outPath, ok: ok, lines: lines)
            } catch {
                state = .failed("\(error)")
            }
            let final = state
            await MainActor.run {
                self.trim = final
                completion()
            }
        }
    }

    /// J K L shuttle, space, arrows for one frame, I and O marks, X clears, F flags. Returns true if handled.
    func handle(_ e: NSEvent, duration: Double, close: () -> Void) -> Bool {
        if e.keyCode == 53 { close(); return true }          // esc
        if e.keyCode == 123 { step(-1); return true }        // left
        if e.keyCode == 124 { step(1); return true }         // right
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "l": forward(); return true
        case "j": backward(); return true
        case "k": stop(); return true
        case " ": toggle(); return true
        case "i": setIn(duration); return true
        case "o": setOut(duration); return true
        case "x": clearMarks(); return true
        case "f": onFlag?(); return true
        default: return false
        }
    }
}

final class KeyPlayerView: AVPlayerView {
    var onKey: ((NSEvent) -> Bool)?
    var onClick: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    /// AVPlayerView's inner views swallow clicks on the picture, so claim them here.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let fromBottom = isFlipped ? bounds.height - p.y : p.y
        if bounds.contains(p) && fromBottom > 80 { return self }
        return super.hitTest(point)
    }

    /// Click the picture to play or pause. Clicks on the control bar along the bottom go to the bar.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let fromBottom = isFlipped ? bounds.height - p.y : p.y
        if event.clickCount == 1 && fromBottom > 80 {
            window?.makeFirstResponder(self)
            onClick?()
        } else {
            super.mouseDown(with: event)
        }
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

struct PlayerHost: NSViewRepresentable {
    let controller: PlayerController
    let duration: Double
    let onClose: () -> Void

    func makeNSView(context: Context) -> KeyPlayerView {
        let v = KeyPlayerView()
        v.player = controller.player
        v.controlsStyle = .inline
        v.onKey = { e in controller.handle(e, duration: duration, close: onClose) }
        v.onClick = { controller.toggle() }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: KeyPlayerView, context: Context) {
        nsView.onKey = { e in controller.handle(e, duration: duration, close: onClose) }
    }
}

/// Filmstrip that doubles as the trim timeline: click or drag to seek, shaded outside the in and out marks.
struct TrimTimeline: View {
    @Environment(Library.self) private var lib
    let clip: ClipRow
    let controller: PlayerController

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let dur = max(clip.duration, 0.001)
            let pack = lib.thumbs.pack(clip.cid)
            let xIn = CGFloat((controller.markIn ?? 0) / dur) * w
            let xOut = CGFloat((controller.markOut ?? dur) / dur) * w
            ZStack(alignment: .leading) {
                if let pack {
                    HStack(spacing: 0) {
                        ForEach(0..<pack.count, id: \.self) { i in
                            if let img = lib.thumbs.image(clip.cid, i) {
                                Image(nsImage: img).resizable().scaledToFill()
                                    .frame(width: w / CGFloat(pack.count), height: 56).clipped()
                            }
                        }
                    }
                } else {
                    Color.black
                }
                Rectangle().fill(.black.opacity(0.65)).frame(width: max(xIn, 0))
                Rectangle().fill(.black.opacity(0.65)).frame(width: max(w - xOut, 0)).offset(x: xOut)
                if controller.markIn != nil { marker(.green).offset(x: xIn - 1.5) }
                if controller.markOut != nil { marker(.red).offset(x: xOut - 1.5) }
                Rectangle().fill(.white).frame(width: 2).offset(x: CGFloat(controller.now / dur) * w - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let t = min(max(v.location.x / w, 0), 1) * dur
                controller.seek(t)
            })
        }
        .frame(height: 56)
        .background(.black)
    }

    private func marker(_ c: Color) -> some View {
        Rectangle().fill(c).frame(width: 3, height: 56)
    }
}

struct ImageSheet: View {
    let clip: ClipRow
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let img = fullImage ?? lib.thumbs.poster(clip.cid) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 900, minHeight: 540)
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(12)
            }
            HStack(spacing: 10) {
                Text(clip.name).font(.callout).lineLimit(1)
                Button { lib.toggleFlag(clip.cid) } label: {
                    let fc = lib.flagColors[clip.cid]
                    Image(systemName: fc != nil ? "flag.fill" : "flag")
                        .foregroundStyle(fc?.swiftUIColor ?? .secondary)
                }.buttonStyle(.plain).help("Flag (F)")
                Spacer()
                if clip.width > 0 { Text("\(clip.width) × \(clip.height)").font(.caption).foregroundStyle(.secondary) }
                if clip.created > 0 { Text(formatShotDate(clip.created)).font(.caption).foregroundStyle(.secondary) }
                Text(formatSize(clip.size)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .onKeyPress(.escape) { dismiss(); return .handled }
        .task {
            fullImage = await Task.detached(priority: .userInitiated) { NSImage(contentsOfFile: clip.path) }.value
        }
    }
}

struct PlayerSheet: View {
    let clip: ClipRow
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var controller = PlayerController()
    @State private var showChecks = false
    @State private var originalGone = false

    var body: some View {
        VStack(spacing: 0) {
            PlayerHost(controller: controller, duration: clip.duration, onClose: { dismiss() })
                .frame(minWidth: 960, minHeight: 520)
                .overlay(alignment: .center) {
                    if clip.mediaKind == .audio {
                        Image(systemName: "music.note").font(.system(size: 72)).foregroundStyle(.white.opacity(0.25))
                    }
                }
                .overlay(alignment: .topLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
                    .padding(12)
                }
            if clip.mediaKind == .video {
                TrimTimeline(clip: clip, controller: controller)
                trimBar
                trimResult
            }
            HStack {
                Text(clip.name).font(.callout).lineLimit(1)
                Button { lib.toggleFlag(clip.cid) } label: {
                    let fc = lib.flagColors[clip.cid]
                    Image(systemName: fc != nil ? "flag.fill" : "flag")
                        .foregroundStyle(fc?.swiftUIColor ?? .secondary)
                }.buttonStyle(.plain).help("Flag (F)")
                Spacer()
                Text("Click video play/pause   J K L shuttle   Space play   ← → frame   I O set in/out   X clear   F flag   Esc close")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .onAppear {
            controller.onFlag = { lib.toggleFlag(clip.cid) }
            controller.load(clip.url)
        }
        .onDisappear { controller.teardown() }
    }

    // MARK: trim controls

    private var trimBar: some View {
        let (a, b) = controller.range(clip.duration)
        let valid = controller.hasRange(clip.duration)
        var running = false
        if case .running = controller.trim { running = true }
        return HStack(spacing: 12) {
            Text(formatTime(controller.now)).font(.system(.body, design: .monospaced))
            Divider().frame(height: 16)
            Button("Set In  (I)") { controller.setIn(clip.duration) }
            Button("Set Out  (O)") { controller.setOut(clip.duration) }
            Button("Clear  (X)") { controller.clearMarks() }.disabled(controller.markIn == nil && controller.markOut == nil)
            Text("In \(formatTime(a))   Out \(formatTime(b))   Keeps \(formatTime(max(b - a, 0)))")
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            if running { ProgressView().controlSize(.small); Text("Trimming and checking…").font(.callout) }
            Button("Save Trim") {
                controller.saveTrim(clip: clip) {
                    if lib.currentDir == clip.dir { lib.open(clip.dir) }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!valid || running)
            .help("Writes a new file next to the original. Nothing is re-encoded and the original is not touched.")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder private var trimResult: some View {
        switch controller.trim {
        case .idle, .running:
            EmptyView()
        case .failed(let msg):
            resultRow(icon: "xmark.octagon.fill", color: .red,
                      text: "Not trimmed: \(msg). Nothing was written.", path: nil, lines: [])
        case .done(let path, let ok, let lines):
            resultRow(icon: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill", color: ok ? .green : .orange,
                      text: ok ? "Saved \((path as NSString).lastPathComponent). Every check passed."
                                 + (originalGone ? " The original is in the Trash." : "")
                               : "Checks failed. Kept as \((path as NSString).lastPathComponent). Do not use it.",
                      path: path, lines: lines, canTrashOriginal: ok && !originalGone)
        }
    }

    private func resultRow(icon: String, color: Color, text: String, path: String?, lines: [String],
                           canTrashOriginal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(text).font(.callout)
                Spacer()
                if let path {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    if canTrashOriginal {
                        Button("Move Original to Trash…") {
                            // only offered after every check passed; make sure the trimmed file is really there
                            guard FileManager.default.fileExists(atPath: path) else { return }
                            let kept = (path as NSString).lastPathComponent
                            Task { originalGone = await lib.confirmAndTrash(clip, extra: "The trimmed copy “\(kept)” is kept. ") }
                        }
                    }
                    Button(showChecks ? "Hide checks" : "Show checks") { showChecks.toggle() }
                }
            }
            if showChecks && !lines.isEmpty {
                ScrollView {
                    Text(lines.joined(separator: "\n")).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(height: 150)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
    }
}
