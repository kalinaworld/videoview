import SwiftUI

struct SpaceSaverSheet: View {
    let clip: ClipRow
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss

    @State private var preset: SpacePreset = .great
    @State private var shrinkTo1080p = false
    @State private var phase: Phase = .idle
    @State private var encodeTask: Task<Void, Never>? = nil

    enum Phase {
        case idle
        case previewing
        case previewDone(projectedSize: Int64, sampleSize: Int64, sampleDuration: Double)
        case encoding(progress: Double)
        case done(outputPath: String, result: SpaceSaver.VerifyResult, originalTrashed: Bool)
        case failed(String)
    }

    var alreadyHEVC: Bool { ["hvc1", "hev1"].contains(clip.codec) }
    var is4K: Bool { max(clip.width, clip.height) >= 3840 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider()
            if alreadyHEVC {
                alreadyHEVCNotice
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    presetPicker
                    if is4K { shrinkToggle }
                    previewSection
                    actionRow
                    resultSection
                }
                .padding(20)
            }
        }
        .frame(width: 560)
        .onDisappear { encodeTask?.cancel() }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Space Saver").font(.headline)
                Text(clip.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("\(clip.codec.isEmpty ? "unknown codec" : clip.codec)  ·  \(formatSize(clip.size))")
                .font(.caption).foregroundStyle(.secondary)
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.title3)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: - Already HEVC

    private var alreadyHEVCNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 36)).foregroundStyle(.green)
            Text("Already HEVC — not much to save").font(.headline)
            Text("This clip is encoded as \(clip.codec.uppercased()), which is already a modern efficient codec. Re-encoding it would likely produce a bigger file or meaningfully worse quality.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }

    // MARK: - Preset picker

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quality").font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                ForEach(SpacePreset.allCases) { p in
                    presetButton(p)
                }
            }
            Text(preset.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func presetButton(_ p: SpacePreset) -> some View {
        let selected = preset == p
        return Button { preset = p } label: {
            Text(p.rawValue)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shrink toggle

    private var shrinkToggle: some View {
        Toggle("Shrink to 1080p  (currently \(resolutionLabel(clip.width, clip.height)))", isOn: $shrinkTo1080p)
            .onChange(of: shrinkTo1080p) { _, _ in phase = .idle }
    }

    // MARK: - Preview section

    @ViewBuilder private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview").font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                Button("Preview 10 seconds") {
                    runPreview()
                }
                .disabled(isWorking)

                switch phase {
                case .previewing:
                    ProgressView().controlSize(.small)
                    Text("Encoding sample…").font(.callout).foregroundStyle(.secondary)
                case .previewDone(let proj, let sample, _):
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sample: \(formatSize(sample))").font(.callout)
                        Text("Projected full size: \(formatSize(proj))  ·  saves \(savingsPct(proj))%")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                default:
                    if clip.bitrateMbps != nil {
                        Text("Rough estimate: ~\(formatSize(estimatedOutputSize))  ·  saves ~\(Int(preset.estimatedSavings * 100))%")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var estimatedOutputSize: Int64 {
        Int64(Double(clip.size) * (1.0 - preset.estimatedSavings))
    }

    private func savingsPct(_ outputSize: Int64) -> Int {
        guard clip.size > 0 else { return 0 }
        return Int((1.0 - Double(outputSize) / Double(clip.size)) * 100)
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button("Encode") { runEncode() }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
            if case .encoding(let p) = phase {
                ProgressView(value: p)
                    .frame(width: 160)
                Text("\(Int(p * 100))%").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .disabled(isWorking)
        }
    }

    private var isWorking: Bool {
        switch phase {
        case .previewing, .encoding: return true
        default: return false
        }
    }

    // MARK: - Result section

    @ViewBuilder private var resultSection: some View {
        switch phase {
        case .failed(let msg):
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(msg).font(.callout)
            }
            .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

        case .done(let path, let result, let trashed):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: result.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.ok ? .green : .orange)
                    if result.ok {
                        Text("Saved \((path as NSString).lastPathComponent)  ·  saves \(savingsPct(result.outputSize))%\(trashed ? "  ·  Original in Trash" : "")")
                            .font(.callout)
                    } else {
                        Text("Checks failed. Kept as \((path as NSString).lastPathComponent). Do not use it.")
                            .font(.callout)
                    }
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    if result.ok && !trashed {
                        Button("Move Original to Trash…") { trashOriginal(outputPath: path) }
                    }
                }
                ChecksDisclosure(lines: result.checks)
            }
            .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

        default:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func runPreview() {
        encodeTask?.cancel()
        phase = .previewing
        let sampleDuration = 10.0
        let sampleURL = SpaceSaver.sampleOutputURL(for: clip)
        encodeTask = Task {
            do {
                try await SpaceSaver.encode(clip: clip, preset: preset, shrinkTo1080p: shrinkTo1080p,
                                             outputURL: sampleURL, sampleDuration: sampleDuration) { _ in }
                let sampleSize = (try? FileManager.default.attributesOfItem(atPath: sampleURL.path))?[.size] as? Int64 ?? 0
                let actualDuration = min(sampleDuration, clip.duration)
                let projected = actualDuration > 0
                    ? Int64(Double(sampleSize) / actualDuration * clip.duration)
                    : sampleSize
                try? FileManager.default.removeItem(at: sampleURL)
                await MainActor.run { phase = .previewDone(projectedSize: projected, sampleSize: sampleSize, sampleDuration: actualDuration) }
            } catch {
                try? FileManager.default.removeItem(at: sampleURL)
                await MainActor.run { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func runEncode() {
        encodeTask?.cancel()
        phase = .encoding(progress: 0)
        let outputURL = SpaceSaver.outputURL(for: clip)
        encodeTask = Task {
            do {
                try await SpaceSaver.encode(clip: clip, preset: preset, shrinkTo1080p: shrinkTo1080p,
                                             outputURL: outputURL) { p in
                    Task { @MainActor in phase = .encoding(progress: p) }
                }
                let result = await SpaceSaver.verify(original: clip, outputURL: outputURL)
                if !result.ok { try? FileManager.default.trashItem(at: outputURL, resultingItemURL: nil) }
                await MainActor.run {
                    phase = .done(outputPath: outputURL.path, result: result, originalTrashed: false)
                    if lib.currentDir == clip.dir { lib.open(clip.dir) }
                }
            } catch {
                try? FileManager.default.trashItem(at: outputURL, resultingItemURL: nil)
                await MainActor.run { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func trashOriginal(outputPath: String) {
        guard FileManager.default.fileExists(atPath: outputPath) else { return }
        let kept = (outputPath as NSString).lastPathComponent
        Task {
            let gone = await lib.confirmAndTrash(clip, extra: "The Space Saver copy \"\(kept)\" is kept. ")
            if gone, case .done(let p, let r, _) = phase {
                phase = .done(outputPath: p, result: r, originalTrashed: true)
            }
        }
    }
}

// MARK: - Checks disclosure

private struct ChecksDisclosure: View {
    let lines: [String]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
        } label: {
            Text(expanded ? "Hide checks" : "Show checks").font(.caption)
        }
    }
}
