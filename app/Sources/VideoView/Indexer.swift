import Foundation
import AVFoundation
import CryptoKit
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// Identifies files and extracts metadata plus small frames. Never writes to a clip.
enum Indexer {
    static let videoExts: Set<String> = ["mov", "mp4", "m4v", "mts", "m2ts", "3gp"]

    /// Content id: file size plus the first and last 64 KB. Cheap on the NAS, survives renames and moves.
    static func contentID(path: String, size: Int64) -> String {
        func hex(_ d: SHA256.Digest) -> String { d.prefix(12).map { String(format: "%02x", $0) }.joined() }
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return "p" + hex(SHA256.hash(data: Data(path.utf8)))
        }
        defer { try? fh.close() }
        var h = SHA256()
        var sz = size
        h.update(data: Data(bytes: &sz, count: 8))
        if let head = try? fh.read(upToCount: 65536) { h.update(data: head) }
        if size > 131072 {
            try? fh.seek(toOffset: UInt64(size - 65536))
            if let tail = try? fh.read(upToCount: 65536) { h.update(data: tail) }
        }
        return hex(h.finalize())
    }

    static let modelNames: [String: String] = [
        "ILCE-7RM5": "Sony A7R V", "ILCE-7RM4": "Sony A7R IV", "ILCE-7RM3": "Sony A7R III",
        "ILCE-7M4": "Sony A7 IV", "ILCE-7SM3": "Sony A7S III", "ILCE-1": "Sony A1",
    ]

    /// Sony cameras store make and model in a top-level meta/xml box that AVFoundation does not expose.
    static func containerCamera(path: String) -> String {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber,
              let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)),
              let top = try? topLevel(fh, size.intValue) else { return "" }
        defer { try? fh.close() }
        for t in top where t.type == "meta" && t.size < 2_000_000 {
            guard let bytes = try? readBytes(fh, t.pos, t.size) else { continue }
            let text = String(decoding: bytes, as: UTF8.self)
            func attr(_ name: String) -> String? {
                guard let re = try? NSRegularExpression(pattern: name + "=\"([^\"]+)\""),
                      let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let r = Range(m.range(at: 1), in: text) else { return nil }
                return String(text[r])
            }
            if let model = attr("modelName") {
                if let nice = modelNames[model] { return nice }
                let make = attr("manufacturer") ?? ""
                return make.isEmpty || model.hasPrefix(make) ? model : "\(make) \(model)"
            }
        }
        return ""
    }

    static func fourCC(_ v: FourCharCode) -> String {
        let b = [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]
        return String(bytes: b, encoding: .ascii) ?? ""
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.68] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Reads metadata and writes the packed thumbnails. Returns the row with status 1 (ready) or 2 (failed).
    /// Returns status 0 if cancelled so it is retried next time.
    static func process(_ row: ClipRow, thumbs: ThumbStore) async -> ClipRow {
        var r = row
        let asset = AVURLAsset(url: row.url)
        do {
            let dur = try await asset.load(.duration).seconds
            guard dur.isFinite, dur > 0,
                  let vt = try await asset.loadTracks(withMediaType: .video).first else {
                r.status = 2
                return r
            }
            let (nat, fps, tf, fds) = try await vt.load(.naturalSize, .nominalFrameRate, .preferredTransform, .formatDescriptions)
            let rotated = abs(tf.b) > 0.5
            r.duration = dur
            r.width = Int(rotated ? nat.height : nat.width)
            r.height = Int(rotated ? nat.width : nat.height)
            r.fps = Double(fps)
            if let fd = fds.first { r.codec = fourCC(CMFormatDescriptionGetMediaSubType(fd)) }
            if let item = try? await asset.load(.creationDate), let d = try? await item.load(.dateValue) {
                r.created = d.timeIntervalSince1970
            }
            let meta = (try? await asset.load(.commonMetadata)) ?? []
            func str(_ id: AVMetadataIdentifier) async -> String {
                let items = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id)
                guard let it = items.first, let s = try? await it.load(.stringValue) else { return "" }
                return s
            }
            let make = await str(.commonIdentifierMake), model = await str(.commonIdentifierModel)
            r.camera = model.hasPrefix(make) || make.isEmpty ? model : (model.isEmpty ? make : "\(make) \(model)")
            if r.camera.isEmpty { r.camera = containerCamera(path: row.path) }

            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 420, height: 420)
            gen.requestedTimeToleranceBefore = .positiveInfinity  // fast: snap to nearby keyframes
            gen.requestedTimeToleranceAfter = .positiveInfinity
            let n = dur < 3 ? 6 : 24
            var frames: [Data?] = []
            for i in 0..<n {
                if Task.isCancelled { r.status = 0; return r }
                let t = CMTime(seconds: dur * (Double(i) + 0.5) / Double(n), preferredTimescale: 600)
                if let img = try? await gen.image(at: t).image, let d = jpeg(img) { frames.append(d) } else { frames.append(nil) }
            }
            // fill gaps from the nearest good frame so frame index still maps to time
            guard let firstGood = frames.firstIndex(where: { $0 != nil }) else { r.status = 2; return r }
            var filled: [Data] = []
            var last = frames[firstGood]!
            for f in frames { if let f = f { last = f }; filled.append(last) }
            try thumbs.write(cid: r.cid, frames: filled, poster: min(n / 4, filled.count - 1))
            r.status = 1
        } catch {
            r.status = 2
        }
        return r
    }
}
