import Foundation
import CryptoKit

// Video View spike, step 3: container structure check (no exiftool needed).
// Usage:
//   spike atoms <clip>                 prints the box tree (what the container holds)
//   spike atoms <original> <trimmed>   compares metadata-like boxes and the container creation time
// Reads headers only (skips the video data), so it is fast even on large files.

struct BoxInfo {
    var key: String
    var path: String
    var type: String
    var offset: UInt64
    var size: UInt64
    var hash: String?
}

struct FileScan {
    var boxes: [BoxInfo] = []
    var creation: Date? = nil
    var modification: Date? = nil
    var fileSize: UInt64 = 0
}

let boxContainers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "edts", "dinf", "meta", "ilst", "mvex"]

func be32(_ b: [UInt8], _ o: Int) -> UInt64 {
    return UInt64(b[o]) << 24 | UInt64(b[o + 1]) << 16 | UInt64(b[o + 2]) << 8 | UInt64(b[o + 3])
}

func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
    return be32(b, o) << 32 | be32(b, o + 4)
}

func readBytes(_ fh: FileHandle, _ off: UInt64, _ n: Int) -> [UInt8] {
    do {
        try fh.seek(toOffset: off)
        return [UInt8](try fh.read(upToCount: n) ?? Data())
    } catch {
        return []
    }
}

func scanBoxes(_ fh: FileHandle, _ start: UInt64, _ end: UInt64, _ prefix: String, _ parent: String,
               _ out: inout [BoxInfo], _ counts: inout [String: Int]) {
    var pos = start
    while pos + 8 <= end {
        let h = readBytes(fh, pos, 16)
        guard h.count >= 8 else { break }
        var size = be32(h, 0)
        let type = String(bytes: h[4..<8], encoding: .isoLatin1) ?? "????"
        var header: UInt64 = 8
        if size == 1 {
            guard h.count >= 16 else { break }
            size = be64(h, 8)
            header = 16
        } else if size == 0 {
            size = end - pos
        }
        guard size >= header, pos + size <= end else { break }

        var name = type
        if type == "uuid" {
            let u = readBytes(fh, pos + header, 16)
            name = "uuid:" + u.map { String(format: "%02x", $0) }.joined()
        }
        let path = prefix + "/" + name
        let idx = counts[path, default: 0]
        counts[path] = idx + 1

        let topLevel = prefix.isEmpty
        let skipTop: Set<String> = ["ftyp", "moov", "mdat", "free", "skip", "wide"]
        let metaish = path.contains("udta") || path.contains("/meta") || path.contains("ilst")
            || path.contains("uuid") || type == "XML " || (topLevel && !skipTop.contains(type))
        var info = BoxInfo(key: "\(path)#\(idx)", path: path, type: type, offset: pos, size: size, hash: nil)
        if metaish && size <= 4_000_000 {
            let all = readBytes(fh, pos, Int(size))
            if !all.isEmpty {
                let digest = SHA256.hash(data: Data(all))
                info.hash = digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
            }
        }
        out.append(info)

        let descend = (boxContainers.contains(type) || parent == "ilst") && type != "stbl"
        if descend {
            var childStart = pos + header
            if type == "meta" {
                let f = readBytes(fh, childStart, 4)
                if f.count == 4 && f.allSatisfy({ $0 == 0 }) { childStart += 4 }
            }
            scanBoxes(fh, childStart, pos + size, path, type, &out, &counts)
        }
        pos += size
    }
}

func scanFile(_ url: URL) -> FileScan? {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? fh.close() }
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    var scan = FileScan()
    scan.fileSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    var counts: [String: Int] = [:]
    scanBoxes(fh, 0, scan.fileSize, "", "", &scan.boxes, &counts)

    if let m = scan.boxes.first(where: { $0.path == "/moov/mvhd" }) {
        let b = readBytes(fh, m.offset + 8, 24)
        if b.count >= 20 {
            var c: UInt64 = 0
            var md: UInt64 = 0
            if b[0] == 1 {
                c = be64(b, 4)
                md = be64(b, 12)
            } else {
                c = be32(b, 4)
                md = be32(b, 8)
            }
            func toDate(_ s: UInt64) -> Date? {
                return s == 0 ? nil : Date(timeIntervalSince1970: Double(s) - 2_082_844_800)
            }
            scan.creation = toDate(c)
            scan.modification = toDate(md)
        }
    }
    return scan
}

func runAtoms(_ args: [String]) {
    var report: [String] = []
    func log(_ s: String = "") { print(s); report.append(s) }
    let iso = ISO8601DateFormatter()
    func d(_ x: Date?) -> String { x.map { iso.string(from: $0) } ?? "none" }

    guard let first = args.first else {
        print("usage: spike atoms <clip>   or   spike atoms <original> <trimmed>")
        return
    }
    let aURL = URL(fileURLWithPath: first).standardizedFileURL
    guard let a = scanFile(aURL) else { print("Cannot read \(aURL.path)"); return }

    if args.count == 1 {
        log("Container structure of \(aURL.lastPathComponent) (sample tables and video data not expanded)")
        log("Container creation time: \(d(a.creation))")
        log("")
        for b in a.boxes {
            let depth = b.path.split(separator: "/").count - 1
            let name = String(b.path.split(separator: "/").last ?? "")
            log(String(repeating: "  ", count: depth) + "\(name)  \(b.size) bytes" + (b.hash.map { "  [\($0)]" } ?? ""))
        }
        return
    }

    let bURL = URL(fileURLWithPath: args[1]).standardizedFileURL
    guard let b = scanFile(bURL) else { print("Cannot read \(bURL.path)"); return }
    let bMap = Dictionary(uniqueKeysWithValues: b.boxes.map { ($0.key, $0) })
    log("Original: \(aURL.lastPathComponent)")
    log("Trimmed:  \(bURL.lastPathComponent)")
    log("")

    var problems = 0
    log("METADATA-LIKE BOXES (user data, meta, uuid, extra top-level boxes)")
    for box in a.boxes where box.hash != nil {
        let name = box.key
        if let other = bMap[box.key] {
            if other.hash == box.hash {
                log("  SAME       \(name)  \(box.size) bytes")
            } else {
                log("  DIFFERENT  \(name)  \(box.size) -> \(other.size) bytes")
                problems += 1
            }
        } else {
            log("  MISSING    \(name)  \(box.size) bytes")
            problems += 1
        }
    }
    let aKeys = Set(a.boxes.map { $0.key })
    for box in b.boxes where box.hash != nil && !aKeys.contains(box.key) {
        log("  ADDED      \(box.key)  \(box.size) bytes")
    }

    log("")
    log("OTHER STRUCTURE")
    let ignore: Set<String> = ["free", "skip", "wide"]
    var structureMissing = 0
    for box in a.boxes where box.hash == nil && !ignore.contains(box.type) {
        if bMap[box.key] == nil {
            log("  MISSING    \(box.key)")
            structureMissing += 1
        }
    }
    if structureMissing == 0 { log("  all other boxes present in the trim") }

    log("")
    log("Container creation time:  \(d(a.creation))  ->  \(d(b.creation))")
    let createdOK = a.creation == b.creation
    log("")
    log("RESULT")
    log("  \(problems == 0 ? "PASS" : "CHECK")  metadata-like boxes: \(problems) missing or different")
    log("  \(structureMissing == 0 ? "PASS" : "CHECK")  other structure: \(structureMissing) missing")
    log("  \(createdOK ? "PASS" : "CHECK")  container creation time kept")
    log("  (DIFFERENT can be harmless if AVFoundation rewrote a box in a new layout. Paste this output and we will look.)")

    let out = bURL.deletingLastPathComponent()
        .appendingPathComponent(bURL.deletingPathExtension().lastPathComponent + ".atoms.txt")
    try? report.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    print("Report: \(out.path)")
}
