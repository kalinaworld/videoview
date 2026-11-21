import Foundation
import CoreGraphics
import ImageIO

/// Perceptual fingerprints (a 64-bit "dHash" per cached frame) used to find clips that look the same but are not
/// byte-identical: re-encodes, exports, trimmed copies. It only reads the cached thumbnails and never opens a clip.
enum Fingerprint {
    /// One hash per cached frame. nil marks a flat frame (black, white, a fade) that says nothing about the clip.
    static func hashes(from pack: Pack) -> [UInt64?] {
        (0..<pack.count).map { i in pack.frame(i).flatMap { dHash($0) } }
    }

    /// Shrinks the frame to 9x8 gray and records, row by row, whether each pixel is brighter than its right neighbor.
    static func dHash(_ jpeg: Data) -> UInt64? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = 9, h = 8
        var px = [UInt8](repeating: 0, count: w * h)
        let drew = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew, let lo = px.min(), let hi = px.max(), hi &- lo >= 14 else { return nil }  // flat frame
        var bits: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                bits <<= 1
                if px[y * w + x] > px[y * w + x + 1] { bits |= 1 }
            }
        }
        return bits
    }

    static func encode(_ hs: [UInt64?]) -> String {
        hs.map { $0.map { String($0, radix: 16) } ?? "-" }.joined(separator: ",")
    }

    static func decode(_ s: String) -> [UInt64?] {
        s.split(separator: ",", omittingEmptySubsequences: false).map { part -> UInt64? in
            part == "-" ? nil : UInt64(part, radix: 16)
        }
    }
}

struct ClipPrint: Sendable {
    let cid: String
    let duration: Double
    let aspect: Double
    let hashes: [UInt64?]   // frame i was taken at duration * (i + 0.5) / hashes.count
}

/// Decides whether two fingerprints belong to clips that look the same. Deliberately cautious: a "similar" result is a
/// hint for the person to check, and nothing in the app acts on it.
enum Similarity {
    static let maxBits = 10          // frames match when at most this many of the 64 bits differ
    static let needFraction = 0.8    // share of usable frames that must match

    static func dist(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    static func similar(_ x: ClipPrint, _ y: ClipPrint) -> Bool {
        guard x.aspect > 0, y.aspect > 0, abs(x.aspect / y.aspect - 1) < 0.04 else { return false }
        let (s, l) = x.duration <= y.duration ? (x, y) : (y, x)
        guard s.duration >= 1, !s.hashes.isEmpty, !l.hashes.isEmpty else { return false }
        let tolerance = max(0.5, 0.02 * l.duration)
        return l.duration - s.duration <= tolerance ? aligned(s, l) : trimmed(s, l)
    }

    /// Same length: compare frames at the same moment (a re-encode or export of the same clip).
    private static func aligned(_ s: ClipPrint, _ l: ClipPrint) -> Bool {
        let ns = s.hashes.count, nl = l.hashes.count
        var comparable = 0, good = 0
        for i in 0..<ns {
            guard let a = s.hashes[i] else { continue }
            let j = min(nl - 1, Int((Double(i) + 0.5) / Double(ns) * Double(nl)))
            guard let b = l.hashes[j] else { continue }
            comparable += 1
            if dist(a, b) <= maxBits { good += 1 }
        }
        return comparable >= 3 && Double(good) >= needFraction * Double(comparable)
    }

    /// Different length: the shorter clip should be a slice of the longer one. Every frame of the shorter clip must find
    /// a match in the longer one, and the matches must agree on one consistent time offset.
    private static func trimmed(_ s: ClipPrint, _ l: ClipPrint) -> Bool {
        let ns = s.hashes.count, nl = l.hashes.count
        let usable = s.hashes.compactMap { $0 }.count
        guard usable >= 4 else { return false }
        let stepS = s.duration / Double(ns), stepL = l.duration / Double(nl)
        var shifts: [Double] = []
        var misses = 0
        let allowedMisses = Int((1 - needFraction) * Double(usable))
        for i in 0..<ns {
            guard let a = s.hashes[i] else { continue }
            var best = 65, bestJ = 0
            for j in 0..<nl {
                guard let b = l.hashes[j] else { continue }
                let d = dist(a, b)
                if d < best { best = d; bestJ = j }
            }
            if best <= maxBits {
                shifts.append((Double(bestJ) + 0.5) * stepL - (Double(i) + 0.5) * stepS)
            } else {
                misses += 1
                if misses > allowedMisses { return false }   // early exit keeps big libraries fast
            }
        }
        guard shifts.count >= 4 else { return false }
        let sorted = shifts.sorted()
        let offset = sorted[sorted.count / 2]
        guard offset > -stepL, offset < l.duration - s.duration + stepL else { return false }
        let inliers = shifts.filter { abs($0 - offset) <= 1.5 * stepL }.count
        return Double(inliers) >= needFraction * Double(usable)
    }

    /// Compares every pair. Returns clip id to the ids of its look-alikes, or nil if cancelled.
    static func findSimilar(_ prints: [ClipPrint]) -> [String: [String]]? {
        var out: [String: [String]] = [:]
        for i in 0..<prints.count {
            if Task.isCancelled { return nil }
            for j in (i + 1)..<prints.count where prints[i].cid != prints[j].cid && similar(prints[i], prints[j]) {
                out[prints[i].cid, default: []].append(prints[j].cid)
                out[prints[j].cid, default: []].append(prints[i].cid)
            }
        }
        return out
    }
}
