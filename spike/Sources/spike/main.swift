import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

// Video View spike, step 1: inventory plus frame extraction timing.
// Read only. Never modifies a clip. Writes a report and poster JPEGs to the output folder.

struct ClipReport: Codable {
    var file: String
    var sizeMB: Double = 0
    var durationSec: Double = 0
    var codec: String = "?"
    var profile: String? = nil
    var bitDepth: Int? = nil
    var width: Int = 0
    var height: Int = 0
    var rotated: Bool = false
    var fps: Double = 0
    var mbps: Double = 0
    var primaries: String? = nil
    var transfer: String? = nil
    var matrix: String? = nil
    var hdrHint: String? = nil
    var make: String? = nil
    var model: String? = nil
    var created: String? = nil
    var hasGPS: Bool = false
    var metadataKeys: [String] = []
    var framesScanned: Int = 0
    var keyframes: Int = 0
    var allIntra: Bool = false
    var medianGOPFrames: Double? = nil
    var maxGOPFrames: Int? = nil
    var gopScanSec: Double = 0
    var fastFirstMs: Double? = nil
    var fastTotalSec: Double? = nil
    var fastOK: Int = 0
    var fastMaxSnapSec: Double? = nil
    var exactFirstMs: Double? = nil
    var exactTotalSec: Double? = nil
    var exactOK: Int = 0
    var posterSaved: Bool = false
    var sidecars: [String] = []
    var notes: [String] = []
}

let videoExts: Set<String> = ["mov", "mp4", "m4v", "mxf"]

func fourCC(_ code: FourCharCode) -> String {
    let b: [UInt8] = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
    return String(decoding: b, as: UTF8.self)
}

func fdExt(_ fd: CMFormatDescription, _ key: CFString) -> Any? {
    return CMFormatDescriptionGetExtension(fd, extensionKey: key)
}

func listFiles(in folder: URL) -> [URL] {
    var out: [URL] = []
    if let en = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
        while let obj = en.nextObject() {
            if let u = obj as? URL, videoExts.contains(u.pathExtension.lowercased()) { out.append(u) }
        }
    }
    return out.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func siblings(of url: URL) -> [String] {
    let dir = url.deletingLastPathComponent().path
    let stem = url.deletingPathExtension().lastPathComponent
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return names.filter { $0.hasPrefix(stem) && $0 != url.lastPathComponent }.sorted()
}

func collectMetadata(_ asset: AVURLAsset) async -> [String: String] {
    var out: [String: String] = [:]
    var items: [AVMetadataItem] = []
    if let m = try? await asset.load(.metadata) { items += m }
    if let fmts = try? await asset.load(.availableMetadataFormats) {
        for f in fmts {
            if let m = try? await asset.loadMetadata(for: f) { items += m }
        }
    }
    for it in items {
        let key = it.identifier?.rawValue ?? (it.key as? String) ?? "?"
        if let s = try? await it.load(.stringValue) {
            out[key] = s
        } else if let d = try? await it.load(.dateValue) {
            out[key] = ISO8601DateFormatter().string(from: d)
        }
    }
    return out
}

struct GOPResult {
    var frames = 0
    var keys = 0
    var median: Double? = nil
    var maxGap: Int? = nil
    var seconds = 0.0
    var error: String? = nil
}

// Reads compressed samples only (no decoding) from the first N seconds and notes which are sync samples.
func scanGOP(asset: AVURLAsset, track: AVAssetTrack, seconds: Double) -> GOPResult {
    var res = GOPResult()
    let t0 = Date()
    do {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else {
            res.error = "reader failed: \(reader.error?.localizedDescription ?? "unknown")"
            return res
        }
        var keyIdx: [Int] = []
        var idx = 0
        while let sb = out.copyNextSampleBuffer() {
            let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
            let notSync = (atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
            if !notSync { keyIdx.append(idx) }
            idx += 1
        }
        res.frames = idx
        res.keys = keyIdx.count
        if keyIdx.count >= 2 {
            let gaps = zip(keyIdx.dropFirst(), keyIdx).map { $0 - $1 }.sorted()
            res.median = Double(gaps[gaps.count / 2])
            res.maxGap = gaps.last
        }
    } catch {
        res.error = "\(error.localizedDescription)"
    }
    res.seconds = Date().timeIntervalSince(t0)
    return res
}

struct FrameTiming {
    var firstMs: Double? = nil
    var totalSec = 0.0
    var ok = 0
    var maxSnap: Double? = nil
}

func timeFrames(asset: AVURLAsset, duration: Double, count: Int, exact: Bool, budgetSec: Double) async -> FrameTiming {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 320, height: 320)
    if exact {
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
    } else {
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
    }
    var t = FrameTiming()
    var maxSnap = 0.0
    let start = Date()
    for i in 0..<count {
        let want = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
        let s = Date()
        do {
            let r = try await gen.image(at: want)
            t.ok += 1
            maxSnap = max(maxSnap, abs(r.actualTime.seconds - want.seconds))
        } catch {
            // counted as a miss
        }
        if i == 0 { t.firstMs = Date().timeIntervalSince(s) * 1000 }
        if Date().timeIntervalSince(start) > budgetSec { break }
    }
    t.totalSec = Date().timeIntervalSince(start)
    t.maxSnap = maxSnap
    return t
}

func savePoster(asset: AVURLAsset, duration: Double, to url: URL) async -> Bool {
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 960, height: 960)
    gen.requestedTimeToleranceBefore = .positiveInfinity
    gen.requestedTimeToleranceAfter = .positiveInfinity
    let at = duration < 1.5 ? duration / 2 : min(max(duration * 0.1, 0.5), 3.0)
    do {
        let r = try await gen.image(at: CMTime(seconds: at, preferredTimescale: 600))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, r.image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    } catch {
        return false
    }
}

func inspect(url: URL, framesN: Int, gopSeconds: Double, noFrames: Bool, outDir: URL) async -> ClipReport {
    var r = ClipReport(file: url.lastPathComponent)
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    r.sizeMB = Double((attrs?[.size] as? NSNumber)?.int64Value ?? 0) / 1_048_576
    r.sidecars = siblings(of: url)
    let asset = AVURLAsset(url: url)
    do {
        let dur = try await asset.load(.duration).seconds
        r.durationSec = dur
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
            r.notes.append("no video track")
            return r
        }
        let size = try await vt.load(.naturalSize)
        let tf = try await vt.load(.preferredTransform)
        let fps = try await vt.load(.nominalFrameRate)
        let rate = try await vt.load(.estimatedDataRate)
        let fds = try await vt.load(.formatDescriptions)
        r.width = Int(size.width)
        r.height = Int(size.height)
        r.rotated = abs(tf.b) > 0.5
        r.fps = Double(fps)
        r.mbps = Double(rate) / 1_000_000

        if let fd = fds.first {
            r.codec = fourCC(CMFormatDescriptionGetMediaSubType(fd))
            r.primaries = fdExt(fd, kCMFormatDescriptionExtension_ColorPrimaries) as? String
            r.transfer = fdExt(fd, kCMFormatDescriptionExtension_TransferFunction) as? String
            r.matrix = fdExt(fd, kCMFormatDescriptionExtension_YCbCrMatrix) as? String
            if let atoms = fdExt(fd, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
                if let d = atoms["hvcC"] as? Data {
                    let b = [UInt8](d)
                    if b.count > 17 {
                        r.bitDepth = Int(b[17] & 7) + 8
                        r.profile = "hevc profile_idc \(b[1] & 0x1f)"
                    }
                } else if let d = atoms["avcC"] as? Data {
                    let b = [UInt8](d)
                    if b.count > 1 { r.profile = "avc profile_idc \(b[1])" }
                }
            }
            if let t = r.transfer {
                if t.contains("2100_HLG") { r.hdrHint = "HLG" }
                else if t.contains("2084") { r.hdrHint = "PQ" }
            }
            if r.primaries == nil && r.transfer == nil { r.notes.append("color untagged (could be log)") }
            if r.codec.hasPrefix("dv") { r.hdrHint = "Dolby Vision" }
        }

        let md = await collectMetadata(asset)
        r.metadataKeys = md.keys.sorted()
        for (k, v) in md {
            let lk = k.lowercased()
            if lk.contains("make") && r.make == nil { r.make = v }
            if lk.contains("model") && r.model == nil { r.model = v }
            if lk.contains("creationdate") && r.created == nil { r.created = v }
            if lk.contains("location") { r.hasGPS = true }
        }
        if r.created == nil, let cd = try? await asset.load(.creationDate), let d = try? await cd.load(.dateValue) {
            r.created = ISO8601DateFormatter().string(from: d)
        }

        let g = scanGOP(asset: asset, track: vt, seconds: gopSeconds)
        r.framesScanned = g.frames
        r.keyframes = g.keys
        r.allIntra = g.frames > 0 && g.keys == g.frames
        r.medianGOPFrames = g.median
        r.maxGOPFrames = g.maxGap
        r.gopScanSec = g.seconds
        if let e = g.error { r.notes.append(e) }
        if r.fps == 0, r.durationSec > 0, g.frames > 0 {
            r.fps = Double(g.frames) / min(r.durationSec, gopSeconds)
        }

        if !noFrames && dur > 0 {
            let fast = await timeFrames(asset: asset, duration: dur, count: framesN, exact: false, budgetSec: 90)
            r.fastFirstMs = fast.firstMs
            r.fastTotalSec = fast.totalSec
            r.fastOK = fast.ok
            r.fastMaxSnapSec = fast.maxSnap
            let exact = await timeFrames(asset: asset, duration: dur, count: framesN, exact: true, budgetSec: 90)
            r.exactFirstMs = exact.firstMs
            r.exactTotalSec = exact.totalSec
            r.exactOK = exact.ok
            let posterDir = outDir.appendingPathComponent("posters")
            try? FileManager.default.createDirectory(at: posterDir, withIntermediateDirectories: true)
            let pu = posterDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jpg")
            r.posterSaved = await savePoster(asset: asset, duration: dur, to: pu)
        }
    } catch {
        r.notes.append("error: \(error.localizedDescription)")
    }
    return r
}

// MARK: main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: spike <folder> [--frames N] [--gop-seconds S] [--out DIR] [--only TEXT] [--no-frames]")
    exit(1)
}
if args[1] == "atoms" {
    runAtoms(Array(args.dropFirst(2)))
    exit(0)
}
if args[1] == "ctrim" {
    await runContainerTrim(Array(args.dropFirst(2)))
    exit(0)
}
if args[1] == "trim" {
    await runTrim(Array(args.dropFirst(2)))
    exit(0)
}
let folder = URL(fileURLWithPath: args[1]).standardizedFileURL
var framesN = 30
var gopSeconds = 60.0
var onlyText: String? = nil
var noFrames = false
var outDir = folder.deletingLastPathComponent().appendingPathComponent("spike-output")
var ai = 2
while ai < args.count {
    switch args[ai] {
    case "--frames": if ai + 1 < args.count { framesN = Int(args[ai + 1]) ?? 30; ai += 1 }
    case "--gop-seconds": if ai + 1 < args.count { gopSeconds = Double(args[ai + 1]) ?? 60; ai += 1 }
    case "--out": if ai + 1 < args.count { outDir = URL(fileURLWithPath: args[ai + 1]).standardizedFileURL; ai += 1 }
    case "--only": if ai + 1 < args.count { onlyText = args[ai + 1]; ai += 1 }
    case "--no-frames": noFrames = true
    default: print("ignoring unknown option \(args[ai])")
    }
    ai += 1
}
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var files = listFiles(in: folder)
if let o = onlyText { files = files.filter { $0.lastPathComponent.localizedCaseInsensitiveContains(o) } }
print("Spike: \(files.count) clips in \(folder.path)")
print("Output: \(outDir.path)\n")

var reports: [ClipReport] = []
for (i, f) in files.enumerated() {
    print("[\(i + 1)/\(files.count)] \(f.lastPathComponent) ...")
    let r = await inspect(url: f, framesN: framesN, gopSeconds: gopSeconds, noFrames: noFrames, outDir: outDir)
    reports.append(r)
    let gop = r.allIntra ? "all-intra" : (r.maxGOPFrames.map { "gop med \(Int(r.medianGOPFrames ?? 0)) max \($0)" } ?? "gop ?")
    let fast = r.fastTotalSec.map { String(format: "fast %.1fs", $0) } ?? "-"
    let exact = r.exactTotalSec.map { String(format: "exact %.1fs", $0) } ?? "-"
    print(String(format: "    %@ %dx%d %.2ffps %.1fs %.0fMbps | %@ | %@ %@", r.codec, r.width, r.height, r.fps, r.durationSec, r.mbps, gop, fast, exact))
}

// Report files
let enc = JSONEncoder()
enc.outputFormatting = [.prettyPrinted, .sortedKeys]
if let data = try? enc.encode(reports) {
    try? data.write(to: outDir.appendingPathComponent("report.json"))
}
var csv = "file,sizeMB,durationSec,codec,profile,bitDepth,width,height,rotated,fps,mbps,primaries,transfer,matrix,hdr,make,model,created,gps,allIntra,keyframes,framesScanned,medianGOP,maxGOP,gopScanSec,fastFirstMs,fast30Sec,fastOK,fastMaxSnapSec,exactFirstMs,exact30Sec,exactOK,sidecars,notes\n"
func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
func n(_ d: Double?) -> String { d.map { String(format: "%.3f", $0) } ?? "" }
for r in reports {
    let cols: [String] = [
        q(r.file), n(r.sizeMB), n(r.durationSec), q(r.codec), q(r.profile), r.bitDepth.map(String.init) ?? "",
        String(r.width), String(r.height), String(r.rotated), n(r.fps), n(r.mbps),
        q(r.primaries), q(r.transfer), q(r.matrix), q(r.hdrHint), q(r.make), q(r.model), q(r.created),
        String(r.hasGPS), String(r.allIntra), String(r.keyframes), String(r.framesScanned),
        n(r.medianGOPFrames), r.maxGOPFrames.map(String.init) ?? "", n(r.gopScanSec),
        n(r.fastFirstMs), n(r.fastTotalSec), String(r.fastOK), n(r.fastMaxSnapSec),
        n(r.exactFirstMs), n(r.exactTotalSec), String(r.exactOK),
        q(r.sidecars.joined(separator: " ")), q(r.notes.joined(separator: "; "))
    ]
    csv += cols.joined(separator: ",") + "\n"
}
try? csv.write(to: outDir.appendingPathComponent("report.csv"), atomically: true, encoding: .utf8)
print("\nDone. Wrote report.json, report.csv and posters/ to \(outDir.path)")
