import Foundation
import AVFoundation
import CoreMedia

// Video View spike, step 2: lossless (passthrough) trim plus verification.
// Never touches the original. Writes <name>_trim.<ext> into the output folder, then checks it.

func keyframeTimes(asset: AVURLAsset, track: AVAssetTrack, from: Double, to: Double) -> [Double] {
    var times: [Double] = []
    guard let reader = try? AVAssetReader(asset: asset) else { return times }
    let start = max(0, from - 20)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 90000),
                                   end: CMTime(seconds: to + 5, preferredTimescale: 90000))
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    out.alwaysCopiesSampleData = false
    reader.add(out)
    guard reader.startReading() else { return times }
    while let sb = out.copyNextSampleBuffer() {
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = (atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        if !notSync { times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
    }
    return times.sorted()
}

func runTrim(_ args: [String]) async {
    var report: [String] = []
    func log(_ s: String = "") { print(s); report.append(s) }
    func f(_ x: Double) -> String { String(format: "%.2f", x) }

    guard let first = args.first, !first.hasPrefix("--") else {
        print("usage: spike trim <clip> [--from S --to E | --cut-start S --cut-end E] [--out DIR]")
        return
    }
    let src = URL(fileURLWithPath: first).standardizedFileURL
    var from: Double? = nil
    var to: Double? = nil
    var cutStart = 0.0
    var cutEnd = 0.0
    var outDirArg: URL? = nil
    var i = 1
    while i < args.count {
        let a = args[i]
        let v: String? = (i + 1 < args.count) ? args[i + 1] : nil
        switch a {
        case "--from": from = v.flatMap(Double.init); i += 1
        case "--to": to = v.flatMap(Double.init); i += 1
        case "--cut-start": cutStart = v.flatMap(Double.init) ?? 0; i += 1
        case "--cut-end": cutEnd = v.flatMap(Double.init) ?? 0; i += 1
        case "--out": if let v = v { outDirArg = URL(fileURLWithPath: v).standardizedFileURL }; i += 1
        default: print("ignoring \(a)")
        }
        i += 1
    }

    let fm = FileManager.default
    let beforeAttrs = try? fm.attributesOfItem(atPath: src.path)
    let beforeSize = (beforeAttrs?[.size] as? NSNumber)?.int64Value ?? 0
    let beforeMtime = beforeAttrs?[.modificationDate] as? Date

    let asset = AVURLAsset(url: src)
    guard let dur = try? await asset.load(.duration).seconds,
          let vt = try? await asset.loadTracks(withMediaType: .video).first else {
        print("Cannot read \(src.path)")
        return
    }
    let start = from ?? cutStart
    let end = to ?? (dur - cutEnd)
    guard start >= 0, end > start, end <= dur + 0.01 else {
        print("Bad range: start \(f(start)) end \(f(end)) clip length \(f(dur))")
        return
    }

    let outDir = outDirArg ?? src.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("spike-output").appendingPathComponent("trims")
    try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    let ext = src.pathExtension
    let stem = src.deletingPathExtension().lastPathComponent
    let outURL = outDir.appendingPathComponent(stem + "_trim." + ext)
    if outURL.path == src.path { print("Refusing: output would overwrite the original"); return }

    log("Trim spike: \(src.lastPathComponent)")
    log("Clip length \(f(dur)) s. Requested in \(f(start)), out \(f(end)) (keeps \(f(end - start)) s).")

    // Where will the cut snap?
    let kf = keyframeTimes(asset: asset, track: vt, from: start, to: end)
    let snapStart = kf.last(where: { $0 <= start + 0.001 }) ?? start
    let nextKF = kf.first(where: { $0 > start + 0.001 })
    log("Keyframe at or before the in point: \(f(snapStart)) s (\(f(start - snapStart)) s earlier than requested).")
    if let n = nextKF { log("Next keyframe after the in point: \(f(n)) s.") }
    log("")

    // Export (no re-encode)
    if fm.fileExists(atPath: outURL.path) { try? fm.removeItem(at: outURL) }
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        log("Could not create a passthrough export session for this file.")
        return
    }
    session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 90000),
                                    end: CMTime(seconds: end, preferredTimescale: 90000))
    let fileType: AVFileType = (ext.lowercased() == "mp4" || ext.lowercased() == "m4v") ? .mp4 : .mov
    let t0 = Date()
    do {
        try await session.export(to: outURL, as: fileType)
    } catch {
        log("EXPORT FAILED: \(error.localizedDescription)")
        return
    }
    log("Exported \(outURL.lastPathComponent) in \(f(Date().timeIntervalSince(t0))) s.")
    log("")

    // Verify
    var checks: [(String, Bool, String)] = []
    let out = AVURLAsset(url: outURL)
    let outDur = (try? await out.load(.duration).seconds) ?? 0
    let playable = (try? await out.load(.isPlayable)) ?? false
    checks.append(("output opens and is playable", playable && outDur > 0, "duration \(f(outDur)) s"))

    let lo = (end - start) - 0.15
    let hi = (end - snapStart) + 0.15
    checks.append(("duration within expected range", outDur >= lo && outDur <= hi,
                   "got \(f(outDur)) s, expected \(f(lo + 0.15)) to \(f(hi - 0.15)) s"))

    let outVT = try? await out.loadTracks(withMediaType: .video).first
    if let ovt = outVT {
        let srcFD = (try? await vt.load(.formatDescriptions))?.first
        let outFD = (try? await ovt.load(.formatDescriptions))?.first
        var sameCodec = false
        var codecNote = ""
        if let s = srcFD, let o = outFD {
            sameCodec = CMFormatDescriptionGetMediaSubType(s) == CMFormatDescriptionGetMediaSubType(o)
            codecNote = "\(fourCC(CMFormatDescriptionGetMediaSubType(s))) -> \(fourCC(CMFormatDescriptionGetMediaSubType(o)))"
        }
        let srcSize = (try? await vt.load(.naturalSize)) ?? .zero
        let outSize = (try? await ovt.load(.naturalSize)) ?? .zero
        checks.append(("same codec and dimensions (no re-encode)", sameCodec && srcSize == outSize,
                       "\(codecNote), \(Int(outSize.width))x\(Int(outSize.height))"))
        let startPTS = (try? await ovt.load(.timeRange).start.seconds) ?? 0
        log("Output video track starts at \(f(startPTS)) s (nonzero can mean an edit list hides pre-roll frames).")
    } else {
        checks.append(("output has a video track", false, ""))
    }

    let srcAudio = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
    let outAudio = (try? await out.loadTracks(withMediaType: .audio))?.count ?? 0
    checks.append(("audio track count kept", srcAudio == outAudio, "\(srcAudio) -> \(outAudio)"))

    let srcMD = await collectMetadata(asset)
    let outMD = await collectMetadata(out)
    let missing = Set(srcMD.keys).subtracting(outMD.keys).sorted()
    let changed = srcMD.keys.filter { outMD[$0] != nil && outMD[$0] != srcMD[$0] }.sorted()
    checks.append(("metadata kept (creation date, camera, GPS)", missing.isEmpty && changed.isEmpty,
                   "source \(srcMD.count) items, output \(outMD.count). missing: \(missing.isEmpty ? "none" : missing.joined(separator: ", ")). changed: \(changed.isEmpty ? "none" : changed.joined(separator: ", "))"))

    let gen = AVAssetImageGenerator(asset: out)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 320, height: 320)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    var decoded = 0
    for t in [0.1, max(0.1, outDur - 0.3)] {
        if (try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600))) != nil { decoded += 1 }
    }
    checks.append(("first and last frames decode", decoded == 2, "\(decoded) of 2"))

    let outAttrs = try? fm.attributesOfItem(atPath: outURL.path)
    let outBytes = (outAttrs?[.size] as? NSNumber)?.int64Value ?? 0
    let sizeRatio = beforeSize > 0 ? Double(outBytes) / Double(beforeSize) : 0
    let durRatio = dur > 0 ? outDur / dur : 0
    checks.append(("file shrank in proportion to what was cut", abs(sizeRatio - durRatio) < 0.15,
                   "size \(f(Double(outBytes) / 1_048_576)) MB of \(f(Double(beforeSize) / 1_048_576)) MB (\(Int(sizeRatio * 100))%), duration \(Int(durRatio * 100))%"))

    let afterAttrs = try? fm.attributesOfItem(atPath: src.path)
    let afterSize = (afterAttrs?[.size] as? NSNumber)?.int64Value ?? -1
    let afterMtime = afterAttrs?[.modificationDate] as? Date
    checks.append(("original untouched", afterSize == beforeSize && afterMtime == beforeMtime, "size and modified time unchanged"))

    log("VERIFICATION")
    for (name, ok, detail) in checks {
        log("  \(ok ? "PASS" : "FAIL")  \(name)  [\(detail)]")
    }
    let allOK = checks.allSatisfy { $0.1 }
    log("")
    log(allOK ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED, see above")
    let reportURL = outDir.appendingPathComponent(stem + "_trim.verify.txt")
    try? report.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    print("Report: \(reportURL.path)")
}
