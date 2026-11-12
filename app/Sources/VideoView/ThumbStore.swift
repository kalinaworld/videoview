import Foundation
import AppKit

/// Packed thumbnails: one file per clip (by content id) holding all small JPEG frames.
/// Format (little endian): magic u32, count u32, posterIndex u32, count x (offset u32, length u32), then JPEG bytes.
/// Lives in ~/Library/Caches (internal SSD), size capped, safe to delete: it rebuilds from the clips.
struct Pack {
    let data: Data
    let count: Int
    let poster: Int

    private func u32(_ o: Int) -> Int {
        data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    }

    init?(_ data: Data) {
        guard data.count >= 12 else { return nil }
        self.data = data
        let m = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
        guard m == Int(ThumbStore.magic) else { return nil }
        count = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        poster = data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
        guard count > 0, data.count >= 12 + 8 * count else { return nil }
    }

    func frame(_ i: Int) -> Data? {
        guard i >= 0, i < count else { return nil }
        let off = u32(12 + 8 * i), len = u32(16 + 8 * i)
        guard off + len <= data.count else { return nil }
        return data.subdata(in: off..<(off + len))
    }
}

private final class PackBox { let pack: Pack; init(_ p: Pack) { pack = p } }

final class ThumbStore: @unchecked Sendable {
    static let magic: UInt32 = 0x3154_5656  // "VVT1"
    let root: URL
    private let packCache = NSCache<NSString, PackBox>()
    private let imageCache = NSCache<NSString, NSImage>()

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("VideoView/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        packCache.totalCostLimit = 256 << 20
        imageCache.countLimit = 600
    }

    func url(_ cid: String) -> URL { root.appendingPathComponent(cid + ".vvt") }
    func exists(_ cid: String) -> Bool { FileManager.default.fileExists(atPath: url(cid).path) }

    func write(cid: String, frames: [Data], poster: Int) throws {
        var out = Data()
        func put(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        put(Int(Self.magic)); put(frames.count); put(poster)
        var offset = 12 + 8 * frames.count
        for f in frames { put(offset); put(f.count); offset += f.count }
        for f in frames { out.append(f) }
        let tmp = url(cid).appendingPathExtension("tmp")
        try out.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(url(cid), withItemAt: tmp)
        if !exists(cid) { try FileManager.default.moveItem(at: tmp, to: url(cid)) }
        packCache.removeObject(forKey: cid as NSString)
        for i in 0..<frames.count { imageCache.removeObject(forKey: "\(cid)#\(i)" as NSString) }
    }

    func pack(_ cid: String) -> Pack? {
        if let b = packCache.object(forKey: cid as NSString) { return b.pack }
        guard let d = try? Data(contentsOf: url(cid), options: .mappedIfSafe), let p = Pack(d) else { return nil }
        packCache.setObject(PackBox(p), forKey: cid as NSString, cost: d.count)
        return p
    }

    func image(_ cid: String, _ index: Int) -> NSImage? {
        let key = "\(cid)#\(index)" as NSString
        if let i = imageCache.object(forKey: key) { return i }
        guard let p = pack(cid), let d = p.frame(index), let img = NSImage(data: d) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    func poster(_ cid: String) -> NSImage? {
        guard let p = pack(cid) else { return nil }
        return image(cid, p.poster)
    }

    // MARK: cache size cap

    func totalBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Deletes the oldest packs until the cache is under the cap.
    func trim(toBytes cap: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: keys)) ?? []
        var items: [(URL, Int, Date)] = files.map {
            let v = try? $0.resourceValues(forKeys: Set(keys))
            return ($0, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
        }
        var total = items.reduce(0) { $0 + $1.1 }
        guard total > cap else { return }
        items.sort { $0.2 < $1.2 }
        for (u, size, _) in items where total > cap {
            try? FileManager.default.removeItem(at: u)
            total -= size
        }
        packCache.removeAllObjects()
        imageCache.removeAllObjects()
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        packCache.removeAllObjects()
        imageCache.removeAllObjects()
    }
}
