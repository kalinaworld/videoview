import Foundation
import CryptoKit
import AVFoundation

// Lossless container-level trim for MP4/MOV (not fragmented). Swift port of spike/py/mp4trim.py.
// Keeps EVERY track and box. Copies selected sample bytes untouched, rewrites sample tables, edit lists
// and durations only. Never modifies the source. Writes <out>.partial, verifies by re-parsing, renames.

struct TrimUnsupported: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

// MARK: byte helpers

extension Array where Element == UInt8 {
    func u16(_ o: Int) -> Int { Int(self[o]) << 8 | Int(self[o + 1]) }
    func i16(_ o: Int) -> Int { Int(Int16(truncatingIfNeeded: u16(o))) }
    func u32(_ o: Int) -> Int {
        Int(self[o]) << 24 | Int(self[o + 1]) << 16 | Int(self[o + 2]) << 8 | Int(self[o + 3])
    }
    func i32(_ o: Int) -> Int { Int(Int32(truncatingIfNeeded: u32(o))) }
    func u64(_ o: Int) -> Int { (u32(o) << 32) | u32(o + 4) }
    func i64(_ o: Int) -> Int { Int(Int64(truncatingIfNeeded: UInt64(u32(o)) << 32 | UInt64(u32(o + 4)))) }
}

struct ByteWriter {
    var b: [UInt8] = []
    mutating func u8(_ v: Int) { b.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { u8(v >> 8); u8(v) }
    mutating func u32(_ v: Int) { u8(v >> 24); u8(v >> 16); u8(v >> 8); u8(v) }
    mutating func i32(_ v: Int) { u32(Int(UInt32(truncatingIfNeeded: v))) }
    mutating func u64(_ v: Int) { u32(v >> 32); u32(v & 0xFFFF_FFFF) }
    mutating func i64(_ v: Int) { u64(v) }
    mutating func raw(_ a: [UInt8]) { b.append(contentsOf: a) }
}

func fourcc(_ s: String) -> [UInt8] { Array(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }) }
func typeString(_ b: ArraySlice<UInt8>) -> String {
    String(b.map { Character(UnicodeScalar($0)) })
}

let containerTypes: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts"]
let rebuiltTypes: Set<String> = ["mvhd", "tkhd", "edts", "elst", "mdhd", "stts", "ctts", "stss", "stsc",
                                 "stsz", "stco", "co64", "sdtp", "sbgp", "cslg"]

// MARK: boxes

final class MBox {
    let type: String
    var payload: [UInt8]
    var children: [MBox]?
    init(_ type: String, payload: [UInt8] = [], children: [MBox]? = nil) {
        self.type = type; self.payload = payload; self.children = children
    }
    func bytes() -> [UInt8] {
        var body: [UInt8] = []
        if let ch = children { for c in ch { body.append(contentsOf: c.bytes()) } } else { body = payload }
        var w = ByteWriter()
        w.u32(8 + body.count)
        w.raw(fourcc(type))
        w.raw(body)
        return w.b
    }
    func find(_ t: String) -> MBox? { children?.first { $0.type == t } }
    func findAll(_ t: String) -> [MBox] { (children ?? []).filter { $0.type == t } }
}

func parseBoxes(_ buf: [UInt8], _ start: Int, _ end: Int) throws -> [MBox] {
    var out: [MBox] = []
    var o = start
    while o + 8 <= end {
        var sz = buf.u32(o)
        let typ = typeString(buf[(o + 4)..<(o + 8)])
        var hl = 8
        if sz == 1 { sz = buf.u64(o + 8); hl = 16 } else if sz == 0 { sz = end - o }
        if sz < hl || o + sz > end { throw TrimUnsupported("bad box size inside moov") }
        if containerTypes.contains(typ) {
            out.append(MBox(typ, children: try parseBoxes(buf, o + hl, o + sz)))
        } else {
            out.append(MBox(typ, payload: Array(buf[(o + hl)..<(o + sz)])))
        }
        o += sz
    }
    return out
}

struct TopBox { let type: String; let pos: Int; let size: Int; let hl: Int }

func readBytes(_ fh: FileHandle, _ off: Int, _ n: Int) throws -> [UInt8] {
    try fh.seek(toOffset: UInt64(off))
    guard let d = try fh.read(upToCount: n), d.count == n else { throw TrimUnsupported("short read") }
    return [UInt8](d)
}

func topLevel(_ fh: FileHandle, _ size: Int) throws -> [TopBox] {
    var res: [TopBox] = []
    var pos = 0
    while pos + 8 <= size {
        let h = try readBytes(fh, pos, min(16, size - pos))
        var sz = h.u32(0)
        let typ = typeString(h[4..<8])
        var hl = 8
        if sz == 1 { sz = h.u64(8); hl = 16 } else if sz == 0 { sz = size - pos }
        if sz < hl { throw TrimUnsupported("bad top-level box") }
        res.append(TopBox(type: typ, pos: pos, size: sz, hl: hl))
        pos += sz
    }
    return res
}

typealias Runs = [(Int, Int)]

func sliceRuns(_ runs: Runs, _ k: Int, _ e: Int) -> Runs {
    var out: Runs = []
    var pos = 0
    for (c, v) in runs {
        let a = max(pos, k)
        let b = min(pos + c - 1, e)
        if b >= a {
            let n = b - a + 1
            if let last = out.last, last.1 == v { out[out.count - 1] = (last.0 + n, v) } else { out.append((n, v)) }
        }
        pos += c
        if pos > e { break }
    }
    return out
}

// MARK: track

final class MTrack {
    let trak: MBox
    var handler = ""
    var mts = 0
    var tkhdDur = 0
    var stts: Runs = []
    var ctts: Runs? = nil
    var stss: [Int]? = nil
    var stsc: [(Int, Int, Int)] = []
    var cslg: [UInt8]? = nil
    var sdtp: [UInt8]? = nil
    var sbgp: [([UInt8], Runs)] = []
    var vf: [String: [UInt8]] = [:]
    var chunkOffsets: [Int] = []
    var co64 = false
    var constSize = 0
    var sizes: [Int] = []
    var n = 0
    var elst: [(Int, Int)]? = nil
    var dts: [Int] = []
    var deltas: [Int] = []
    var off: [Int] = []
    var pts: [Int] = []
    var spc: [Int] = []
    var sdi: [Int] = []

    init(_ trak: MBox) throws {
        self.trak = trak
        guard let tkhd = trak.find("tkhd"), let mdia = trak.find("mdia"), let mdhd = mdia.find("mdhd"),
              let minf = mdia.find("minf"), let stbl = minf.find("stbl"), let hdlr = mdia.find("hdlr") else {
            throw TrimUnsupported("track missing required boxes")
        }
        handler = typeString(hdlr.payload[8..<12])
        var p = mdhd.payload
        mts = p[0] == 0 ? p.u32(12) : p.u32(20)
        p = tkhd.payload
        tkhdDur = p[0] == 0 ? p.u32(20) : p.u64(28)
        if let edts = trak.find("edts"), let el = edts.find("elst") {
            let q = el.payload
            let cnt = q.u32(4)
            var ents: [(Int, Int)] = []
            for i in 0..<cnt {
                let seg: Int, mt: Int, ri: Int, rf: Int
                if q[0] == 0 {
                    let o = 8 + 12 * i
                    seg = q.u32(o); mt = q.i32(o + 4); ri = q.i16(o + 8); rf = q.u16(o + 10)
                } else {
                    let o = 8 + 20 * i
                    seg = q.u64(o); mt = q.i64(o + 8); ri = q.i16(o + 16); rf = q.u16(o + 18)
                }
                let rate = Double(ri) + Double(rf) / 65536.0
                if mt != -1 && rate != 1.0 { throw TrimUnsupported("edit list with rate != 1") }
                ents.append((seg, mt))
            }
            elst = ents
        }
        for b in stbl.children ?? [] {
            let t = b.type
            let p = b.payload
            if ["stts", "ctts", "stss", "stsc", "stsz", "stco", "co64", "sdtp", "sbgp", "cslg"].contains(t) {
                vf[t] = Array(p[0..<4])
            }
            switch t {
            case "stts":
                let c = p.u32(4)
                stts = (0..<c).map { (p.u32(8 + 8 * $0), p.u32(12 + 8 * $0)) }
            case "ctts":
                let c = p.u32(4)
                ctts = (0..<c).map { (p.u32(8 + 8 * $0), p.i32(12 + 8 * $0)) }  // signed even in version 0
            case "stss":
                let c = p.u32(4)
                stss = (0..<c).map { p.u32(8 + 4 * $0) }
            case "stsc":
                let c = p.u32(4)
                stsc = (0..<c).map { (p.u32(8 + 12 * $0), p.u32(12 + 12 * $0), p.u32(16 + 12 * $0)) }
            case "stsz":
                constSize = p.u32(4)
                n = p.u32(8)
                if constSize != 0 { sizes = [Int](repeating: constSize, count: n) }
                else { sizes = (0..<n).map { p.u32(12 + 4 * $0) } }
            case "stco":
                let c = p.u32(4)
                chunkOffsets = (0..<c).map { p.u32(8 + 4 * $0) }
            case "co64":
                let c = p.u32(4)
                chunkOffsets = (0..<c).map { p.u64(8 + 8 * $0) }
                co64 = true
            case "sdtp":
                sdtp = Array(p[4...])
            case "sbgp":
                let hl = p[0] == 1 ? 12 : 8
                let c = p.u32(hl)
                let runs: Runs = (0..<c).map { (p.u32(hl + 4 + 8 * $0), p.u32(hl + 8 + 8 * $0)) }
                sbgp.append((Array(p[0..<hl]), runs))
            case "cslg":
                cslg = p
            case "stsd", "sgpd":
                break
            default:
                throw TrimUnsupported("unsupported sample table box \(t)")
            }
        }
        if stts.isEmpty || stsc.isEmpty || sizes.isEmpty && n > 0 || chunkOffsets.isEmpty {
            throw TrimUnsupported("missing sample tables")
        }
        dts.reserveCapacity(n); deltas.reserveCapacity(n)
        var cur = 0
        for (c, d) in stts {
            for i in 0..<c { dts.append(cur + i * d); deltas.append(d) }
            cur += c * d
        }
        if dts.count != n { throw TrimUnsupported("stts/stsz sample count mismatch") }
        if let ct = ctts {
            off.reserveCapacity(n)
            for (c, v) in ct { off.append(contentsOf: [Int](repeating: v, count: c)) }
            if off.count != n { throw TrimUnsupported("ctts/stsz sample count mismatch") }
        } else {
            off = [Int](repeating: 0, count: n)
        }
        pts = (0..<n).map { dts[$0] + off[$0] }
        let nch = chunkOffsets.count
        for (idx, ent) in stsc.enumerated() {
            let nxt = idx + 1 < stsc.count ? stsc[idx + 1].0 : nch + 1
            if nxt > ent.0 {
                for _ in ent.0..<nxt { spc.append(ent.1); sdi.append(ent.2) }
            }
        }
        if spc.count != nch || spc.reduce(0, +) != n { throw TrimUnsupported("stsc/stco/stsz mismatch") }
    }
}

struct ParsedFile {
    let fh: FileHandle
    let top: [TopBox]
    let moov: MBox
    let tracks: [MTrack]
}

func parseFile(_ path: String) throws -> ParsedFile {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
    let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    let top = try topLevel(fh, size)
    if top.contains(where: { $0.type == "moof" || $0.type == "mfra" }) { throw TrimUnsupported("fragmented file") }
    if top.filter({ $0.type == "mdat" }).count != 1 || top.filter({ $0.type == "moov" }).count != 1 {
        throw TrimUnsupported("need exactly one moov and one mdat")
    }
    let mt = top.first { $0.type == "moov" }!
    let buf = try readBytes(fh, mt.pos, mt.size)
    let moov = MBox("moov", children: try parseBoxes(buf, mt.hl, mt.size))
    let tracks = try moov.findAll("trak").map { try MTrack($0) }
    return ParsedFile(fh: fh, top: top, moov: moov, tracks: tracks)
}

func mvhdInfo(_ moov: MBox) -> (ts: Int, dur: Int) {
    let p = moov.find("mvhd")!.payload
    return p[0] == 0 ? (p.u32(12), p.u32(16)) : (p.u32(20), p.u64(24))
}

// MARK: planning

func bisectRight(_ a: [Int], _ x: Int) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let m = (lo + hi) / 2; if x < a[m] { hi = m } else { lo = m + 1 } }
    return lo
}
func bisectLeft(_ a: [Int], _ x: Int) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let m = (lo + hi) / 2; if a[m] < x { lo = m + 1 } else { hi = m } }
    return lo
}
func rnd(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

struct Chunk { var src: Int; var length: Int; var count: Int; var sdi: Int }
struct Plan {
    var k: Int, e: Int, base: Int
    var pieces: [(Int, Int)]
    var mFirst: Int
    var chunks: [Chunk]
}

func clipEdits(_ tr: MTrack, _ movieTs: Int, _ tin: Int, _ tout: Int) -> [(Int, Int)] {
    let entries = tr.elst ?? [(tr.tkhdDur, 0)]
    var pieces: [(Int, Int)] = []
    var P = 0
    for (seg, mt) in entries {
        let a = max(P, tin)
        let b = min(P + seg, tout)
        if b > a {
            if mt == -1 { pieces.append((b - a, -1)) }
            else { pieces.append((b - a, mt + rnd(Double(a - P) * Double(tr.mts) / Double(movieTs)))) }
        }
        P += seg
    }
    return pieces
}

func planTrack(_ tr: MTrack, _ movieTs: Int, _ tin: Int, _ tout: Int) throws -> Plan {
    let pieces = clipEdits(tr, movieTs, tin, tout)
    let nonempty = pieces.filter { $0.1 != -1 }
    guard let firstP = nonempty.first, let lastP = nonempty.last else {
        throw TrimUnsupported("a track has no media inside the window")
    }
    let mFirst = firstP.1
    let mEnd = lastP.1 + rnd(Double(lastP.0) * Double(tr.mts) / Double(movieTs))
    let pts = tr.pts
    let n = tr.n
    var mono = true
    if n > 1 { for i in 0..<(n - 1) where pts[i] > pts[i + 1] { mono = false; break } }
    var k: Int
    if let ss = tr.stss {
        let cands = ss.map { $0 - 1 }
        let ks = cands.filter { pts[$0] <= mFirst }
        k = ks.last ?? cands[0]
    } else if mono {
        k = max(0, bisectRight(pts, mFirst) - 1)
    } else {
        k = (stride(from: n - 1, through: 0, by: -1).first { pts[$0] <= mFirst }) ?? 0
    }
    if tr.stss == nil && tr.handler == "soun" { k = max(0, k - 2) }  // AAC priming / pre-roll
    var e: Int
    if mono { e = bisectLeft(pts, mEnd) - 1 }
    else { e = (stride(from: n - 1, through: 0, by: -1).first { pts[$0] < mEnd }) ?? k }
    e = max(e, k)
    let base = tr.dts[k]
    var newPieces: [(Int, Int)] = []
    for (dur, mt) in pieces {
        if mt == -1 { newPieces.append((dur, -1)) }
        else {
            if mt - base < 0 { throw TrimUnsupported("negative media time after rebase") }
            newPieces.append((dur, mt - base))
        }
    }
    var chunks: [Chunk] = []
    var s = 0
    for (j, off) in tr.chunkOffsets.enumerated() {
        let cnt = tr.spc[j]
        let a = s, b = s + cnt - 1
        if b >= k && a <= e {
            let lo = max(a, k), hi = min(b, e)
            var skip = 0
            if lo > a { for i in a..<lo { skip += tr.sizes[i] } }
            var len = 0
            for i in lo...hi { len += tr.sizes[i] }
            chunks.append(Chunk(src: off + skip, length: len, count: hi - lo + 1, sdi: tr.sdi[j]))
        }
        s += cnt
        if s > e { break }
    }
    return Plan(k: k, e: e, base: base, pieces: newPieces, mFirst: mFirst, chunks: chunks)
}

// MARK: new tables

struct NewTab {
    var stts: [UInt8] = []
    var ctts: [UInt8]? = nil
    var stss: [UInt8]? = nil
    var stsz: [UInt8] = []
    var stsc: [UInt8] = []
    var sdtp: [UInt8]? = nil
    var sbgp: [[UInt8]] = []
    var cslg: [UInt8]? = nil
    var cslgTrusted = true
    var mediaDur = 0
}

func cslgCalc(_ dts: [Int], _ off: [Int], _ durs: [Int], _ ver: UInt8) -> [UInt8] {
    var least = Int.max, greatest = Int.min, start = Int.max, end = Int.min
    for i in 0..<dts.count {
        let p = dts[i] + off[i]
        least = min(least, off[i]); greatest = max(greatest, off[i])
        start = min(start, p); end = max(end, p + durs[i])
    }
    let shift = max(0, -least)
    var w = ByteWriter()
    for v in [shift, least, greatest, start, end] { if ver == 0 { w.i32(v) } else { w.i64(v) } }
    return w.b
}

func newTrackBoxes(_ tr: MTrack, _ plan: Plan) -> NewTab {
    let k = plan.k, e = plan.e, base = plan.base
    var nt = NewTab()
    var runs = sliceRuns(tr.stts, k, e)
    var w = ByteWriter()
    w.raw(tr.vf["stts"]!); w.u32(runs.count)
    for (c, d) in runs { w.u32(c); w.u32(d) }
    nt.stts = w.b
    nt.mediaDur = runs.reduce(0) { $0 + $1.0 * $1.1 }
    if let ct = tr.ctts {
        runs = sliceRuns(ct, k, e)
        w = ByteWriter(); w.raw(tr.vf["ctts"]!); w.u32(runs.count)
        for (c, v) in runs { w.u32(c); w.i32(v) }
        nt.ctts = w.b
    }
    if let ss = tr.stss {
        let list = ss.filter { k <= $0 - 1 && $0 - 1 <= e }.map { $0 - k }
        w = ByteWriter(); w.raw(tr.vf["stss"]!); w.u32(list.count)
        for v in list { w.u32(v) }
        nt.stss = w.b
    }
    let n = e - k + 1
    w = ByteWriter(); w.raw(tr.vf["stsz"]!)
    if tr.constSize != 0 { w.u32(tr.constSize); w.u32(n) }
    else { w.u32(0); w.u32(n); for i in k...e { w.u32(tr.sizes[i]) } }
    nt.stsz = w.b
    var ents: [(Int, Int, Int)] = []
    for (ci, ch) in plan.chunks.enumerated() {
        if let l = ents.last, l.1 == ch.count && l.2 == ch.sdi { continue }
        ents.append((ci + 1, ch.count, ch.sdi))
    }
    w = ByteWriter(); w.raw(tr.vf["stsc"]!); w.u32(ents.count)
    for x in ents { w.u32(x.0); w.u32(x.1); w.u32(x.2) }
    nt.stsc = w.b
    if let sd = tr.sdtp { nt.sdtp = [0, 0, 0, 0] + Array(sd[k...e]) }
    for (hdr, r0) in tr.sbgp {
        let r = sliceRuns(r0, k, e)
        w = ByteWriter(); w.raw(hdr); w.u32(r.count)
        for (c, v) in r { w.u32(c); w.u32(v) }
        nt.sbgp.append(w.b)
    }
    if let cs = tr.cslg {
        let ver = cs[0]
        if cslgCalc(tr.dts, tr.off, tr.deltas, ver) == Array(cs[4...]) {
            let nd = tr.dts[k...e].map { $0 - base }
            nt.cslg = Array(cs[0..<4]) + cslgCalc(nd, Array(tr.off[k...e]), Array(tr.deltas[k...e]), ver)
            nt.cslgTrusted = true
        } else {
            nt.cslgTrusted = false
        }
    }
    return nt
}

func elstBox(_ pieces: [(Int, Int)]) -> MBox {
    let big = pieces.contains { $0.0 >= 1 << 32 || $0.1 >= 1 << 31 || $0.1 < -1 }
    var w = ByteWriter()
    if big {
        w.u32(1 << 24); w.u32(pieces.count)
        for (d, mt) in pieces { w.u64(d); w.i64(mt); w.u16(1); w.u16(0) }
    } else {
        w.u32(0); w.u32(pieces.count)
        for (d, mt) in pieces { w.u32(d); w.i32(mt); w.u16(1); w.u16(0) }
    }
    return MBox("elst", payload: w.b)
}

func patchDur(_ payload: [UInt8], _ offV0: Int, _ offV1: Int, _ value: Int) -> [UInt8] {
    var b = payload
    var w = ByteWriter()
    if b[0] == 0 { w.u32(value); b.replaceSubrange(offV0..<(offV0 + 4), with: w.b) }
    else { w.u64(value); b.replaceSubrange(offV1..<(offV1 + 8), with: w.b) }
    return b
}

func offsetsPayload(_ vf: [UInt8], _ offsets: [Int], _ co64: Bool) -> MBox {
    var w = ByteWriter(); w.raw(vf); w.u32(offsets.count)
    for o in offsets { if co64 { w.u64(o) } else { w.u32(o) } }
    return MBox(co64 ? "co64" : "stco", payload: w.b)
}

func buildStbl(_ stbl: MBox, _ tr: MTrack, _ nt: NewTab, _ offsets: [Int], _ co64: Bool) -> MBox {
    var kids: [MBox] = []
    var sb = nt.sbgp
    for c in stbl.children ?? [] {
        switch c.type {
        case "stts": kids.append(MBox("stts", payload: nt.stts))
        case "ctts": if let x = nt.ctts { kids.append(MBox("ctts", payload: x)) }
        case "stss": if let x = nt.stss { kids.append(MBox("stss", payload: x)) }
        case "stsc": kids.append(MBox("stsc", payload: nt.stsc))
        case "stsz": kids.append(MBox("stsz", payload: nt.stsz))
        case "sdtp": if let x = nt.sdtp { kids.append(MBox("sdtp", payload: x)) }
        case "sbgp": kids.append(MBox("sbgp", payload: sb.removeFirst()))
        case "cslg": if let x = nt.cslg { kids.append(MBox("cslg", payload: x)) }
        case "stco", "co64":
            kids.append(offsetsPayload(tr.vf[c.type]!, offsets, co64))
        default: kids.append(c)
        }
    }
    return MBox("stbl", children: kids)
}

func buildMdia(_ mdia: MBox, _ tr: MTrack, _ nt: NewTab, _ offsets: [Int], _ co64: Bool) -> MBox {
    var kids: [MBox] = []
    for c in mdia.children ?? [] {
        if c.type == "mdhd" {
            kids.append(MBox("mdhd", payload: patchDur(c.payload, 16, 24, nt.mediaDur)))
        } else if c.type == "minf" {
            let mk = (c.children ?? []).map { $0.type == "stbl" ? buildStbl($0, tr, nt, offsets, co64) : $0 }
            kids.append(MBox("minf", children: mk))
        } else { kids.append(c) }
    }
    return MBox("mdia", children: kids)
}

func buildTrak(_ trak: MBox, _ tr: MTrack, _ plan: Plan, _ nt: NewTab, _ offsets: [Int], _ co64: Bool) -> MBox {
    let total = plan.pieces.reduce(0) { $0 + $1.0 }
    var kids: [MBox] = []
    let hadEdts = trak.find("edts") != nil
    let newEdts = MBox("edts", children: [elstBox(plan.pieces)])
    for c in trak.children ?? [] {
        switch c.type {
        case "tkhd": kids.append(MBox("tkhd", payload: patchDur(c.payload, 20, 28, total)))
        case "edts": kids.append(newEdts)
        case "mdia":
            if !hadEdts { kids.append(newEdts) }
            kids.append(buildMdia(c, tr, nt, offsets, co64))
        default: kids.append(c)
        }
    }
    return MBox("trak", children: kids)
}

func buildMoov(_ src: MBox, _ tracks: [MTrack], _ plans: [Plan], _ tabs: [NewTab], _ movieDur: Int,
               _ offs: [[Int]], _ co64: Bool) -> MBox {
    var kids: [MBox] = []
    var ti = 0
    for c in src.children ?? [] {
        if c.type == "mvhd" { kids.append(MBox("mvhd", payload: patchDur(c.payload, 16, 24, movieDur))) }
        else if c.type == "trak" {
            kids.append(buildTrak(c, tracks[ti], plans[ti], tabs[ti], offs[ti], co64)); ti += 1
        } else { kids.append(c) }
    }
    return MBox("moov", children: kids)
}

// MARK: verification helpers

func rawMap(_ boxes: [MBox], _ path: String, _ out: inout [String: [UInt8]]) {
    var counts: [String: Int] = [:]
    for c in boxes {
        let key = path + "/" + c.type
        let idx = counts[key, default: 0]
        counts[key] = idx + 1
        if containerTypes.contains(c.type) { rawMap(c.children ?? [], key + "#\(idx)", &out) }
        else if !rebuiltTypes.contains(c.type) { out[key + "#\(idx)"] = c.bytes() }
    }
}

func sampleDigest(_ tr: MTrack, _ fh: FileHandle, _ lo: Int, _ hi: Int) throws -> String {
    var h = SHA256()
    var s = 0
    for (j, off) in tr.chunkOffsets.enumerated() {
        let cnt = tr.spc[j]
        let a = s, b = s + cnt - 1
        if b >= lo && a <= hi {
            let l = max(a, lo), r = min(b, hi)
            var skip = 0
            if l > a { for i in a..<l { skip += tr.sizes[i] } }
            var length = 0
            for i in l...r { length += tr.sizes[i] }
            try fh.seek(toOffset: UInt64(off + skip))
            while length > 0 {
                guard let d = try fh.read(upToCount: min(length, 8 << 20)), !d.isEmpty else {
                    throw TrimUnsupported("short read")
                }
                h.update(data: d)
                length -= d.count
            }
        }
        s += cnt
        if s > hi { break }
    }
    return h.finalize().map { String(format: "%02x", $0) }.joined()
}

// MARK: result type and engine

struct TrimResult {
    var ok: Bool
    var outPath: String
    var lines: [String]
    var expectedSeconds: Double
}

/// Core trim. Throws TrimUnsupported when the file is outside what we handle (caller can refuse or fall back).
func containerTrim(src srcPath: String, out outPath: String, from tinS: Double?, to toutS: Double?,
                   cutStart: Double, cutEnd: Double, dry: Bool, log: (String) -> Void) throws -> TrimResult {
    let src = URL(fileURLWithPath: srcPath).standardizedFileURL.path
    let out = URL(fileURLWithPath: outPath).standardizedFileURL.path
    if src == out { throw TrimUnsupported("Refusing: output is the source file") }
    if FileManager.default.fileExists(atPath: out) { throw TrimUnsupported("Refusing: output exists: \(out)") }

    let pf = try parseFile(src)
    let (movieTs, movieDur0) = mvhdInfo(pf.moov)
    let totalSec = Double(movieDur0) / Double(movieTs)
    let a = tinS ?? cutStart
    let b = toutS ?? (totalSec - cutEnd)
    guard a >= 0, a < b, b <= totalSec + 0.01 else {
        throw TrimUnsupported(String(format: "Bad range %.3f to %.3f (clip is %.3f s)", a, b, totalSec))
    }
    let tin = rnd(a * Double(movieTs)), tout = rnd(b * Double(movieTs))
    log(String(format: "Source: %@  (%.2f s, %d tracks)", (src as NSString).lastPathComponent, totalSec, pf.tracks.count))
    log(String(format: "Window: %.3f to %.3f s (keeps %.3f s)", a, b, b - a))

    let plans = try pf.tracks.map { try planTrack($0, movieTs, tin, tout) }
    let tabs = zip(pf.tracks, plans).map { newTrackBoxes($0, $1) }
    for (i, (t, p)) in zip(pf.tracks, plans).enumerated() {
        log(String(format: "  track %d %@: samples %d..%d of %d, starts %.3f s before the in point (hidden by edit list)%@",
                   i, t.handler, p.k, p.e, t.n, Double(p.mFirst - t.dts[p.k]) / Double(t.mts),
                   tabs[i].cslgTrusted ? "" : "  [cslg formula not trusted, box dropped]"))
    }
    let movieDur = plans.map { $0.pieces.reduce(0) { $0 + $1.0 } }.max() ?? 0

    let srcSize = pf.top.reduce(0) { $0 + $1.size }
    let totalData = plans.reduce(0) { $0 + $1.chunks.reduce(0) { $0 + $1.length } }
    let co64 = pf.tracks.contains { $0.co64 } || totalData + 1_000_000 >= (1 << 32) - 1
    struct Ref: Comparable {
        var so: Int, ti: Int, ci: Int
        static func < (l: Ref, r: Ref) -> Bool { (l.so, l.ti, l.ci) < (r.so, r.ti, r.ci) }
    }
    var allChunks: [Ref] = []
    for (ti, p) in plans.enumerated() { for (ci, c) in p.chunks.enumerated() { allChunks.append(Ref(so: c.src, ti: ti, ci: ci)) } }
    allChunks.sort()
    let mdatHL = totalData + 8 >= (1 << 32) ? 16 : 8

    func offsets(from base: Int) -> [[Int]] {
        var pos = base
        var res = plans.map { [Int](repeating: 0, count: $0.chunks.count) }
        for r in allChunks { res[r.ti][r.ci] = pos; pos += plans[r.ti].chunks[r.ci].length }
        return res
    }
    let dummy = plans.map { [Int](repeating: 0, count: $0.chunks.count) }
    let moovSize = buildMoov(pf.moov, pf.tracks, plans, tabs, movieDur, dummy, co64).bytes().count

    enum Seg { case mdat(Int), moov(Int), raw([UInt8]) }
    var segs: [Seg] = []
    var pos = 0
    var mdatStart = 0
    for t in pf.top {
        if t.type == "mdat" { mdatStart = pos + mdatHL; segs.append(.mdat(pos)); pos += mdatHL + totalData }
        else if t.type == "moov" { segs.append(.moov(pos)); pos += moovSize }
        else {
            if t.size > (64 << 20) { throw TrimUnsupported("large non-mdat top-level box \(t.type)") }
            segs.append(.raw(try readBytes(pf.fh, t.pos, t.size)))
            pos += t.size
        }
    }
    let finalSize = pos
    let moovBytes = buildMoov(pf.moov, pf.tracks, plans, tabs, movieDur, offsets(from: mdatStart), co64).bytes()
    if moovBytes.count != moovSize { throw TrimUnsupported("internal error: moov size changed") }
    log(String(format: "Output will be %.1f MB (source %.1f MB)", Double(finalSize) / 1048576, Double(srcSize) / 1048576))
    let expected = b - a
    if dry { return TrimResult(ok: true, outPath: out, lines: [], expectedSeconds: expected) }

    let part = out + ".partial"
    let fd = open(part, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    if fd < 0 { throw TrimUnsupported("cannot create \(part) (exists or not writable)") }
    let oh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    for seg in segs {
        switch seg {
        case .raw(let d): try oh.write(contentsOf: Data(d))
        case .moov: try oh.write(contentsOf: Data(moovBytes))
        case .mdat:
            var w = ByteWriter()
            if mdatHL == 8 { w.u32(8 + totalData); w.raw(fourcc("mdat")) }
            else { w.u32(1); w.raw(fourcc("mdat")); w.u64(16 + totalData) }
            try oh.write(contentsOf: Data(w.b))
            for r in allChunks {
                var length = plans[r.ti].chunks[r.ci].length
                try pf.fh.seek(toOffset: UInt64(r.so))
                while length > 0 {
                    guard let d = try pf.fh.read(upToCount: min(length, 8 << 20)), !d.isEmpty else {
                        throw TrimUnsupported("short read from source")
                    }
                    try oh.write(contentsOf: d)
                    length -= d.count
                }
            }
        }
    }
    try oh.synchronize()
    try oh.close()

    let ok = try verify(part: part, pf: pf, plans: plans, identity: tin == 0 && tout >= movieDur0, log: log)
    if !ok {
        try FileManager.default.moveItem(atPath: part, toPath: out + ".FAILED")
        log("VERIFICATION FAILED. Output kept as \(out).FAILED")
        return TrimResult(ok: false, outPath: out + ".FAILED", lines: [], expectedSeconds: expected)
    }
    try FileManager.default.moveItem(atPath: part, toPath: out)
    log("Wrote \(out)")
    return TrimResult(ok: true, outPath: out, lines: [], expectedSeconds: expected)
}

func verify(part: String, pf: ParsedFile, plans: [Plan], identity: Bool, log: (String) -> Void) throws -> Bool {
    log("VERIFICATION (re-parses the new file independently)")
    var ok = true
    func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        log("  \(cond ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
        if !cond { ok = false }
    }
    let of = try parseFile(part)
    check("same number of tracks", of.tracks.count == pf.tracks.count, "\(of.tracks.count)")
    if of.tracks.count != pf.tracks.count { return false }
    for (i, ((t, p), ot)) in zip(zip(pf.tracks, plans), of.tracks).enumerated() {
        let k = p.k, e = p.e, n = e - k + 1
        var good = ot.n == n && ot.sizes == Array(t.sizes[k...e])
            && ot.dts == t.dts[k...e].map { $0 - p.base } && ot.off == Array(t.off[k...e])
        if let ss = t.stss {
            good = good && ot.stss == ss.filter { k <= $0 - 1 && $0 - 1 <= e }.map { $0 - k }
        }
        check("track \(i) sample tables (sizes, timing, keyframes)", good, "\(ot.n) samples")
        let d1 = try sampleDigest(t, pf.fh, k, e)
        let d2 = try sampleDigest(ot, of.fh, 0, n - 1)
        check("track \(i) sample bytes identical to source", d1 == d2, String(d1.prefix(12)))
    }
    var a: [String: [UInt8]] = [:], b: [String: [UInt8]] = [:]
    rawMap(pf.moov.children ?? [], "/moov", &a)
    rawMap(of.moov.children ?? [], "/moov", &b)
    check("all vendor and metadata boxes inside moov byte-identical", a == b, "\(a.count) boxes")
    var topOK = true
    for t in pf.top where t.type != "mdat" && t.type != "moov" {
        let x = try readBytes(pf.fh, t.pos, t.size)
        var found = false
        for t2 in of.top where t2.type == t.type && t2.size == t.size {
            if try readBytes(of.fh, t2.pos, t2.size) == x { found = true; break }
        }
        topOK = topOK && found
    }
    check("all other top-level boxes byte-identical (uuid, meta, ftyp...)", topOK)
    check("top-level box order kept", pf.top.map { $0.type } == of.top.map { $0.type })
    let sm = pf.moov.find("mvhd")!.payload, om = of.moov.find("mvhd")!.payload
    check("container creation and modification time kept",
          sm[0] == 0 ? Array(sm[4..<12]) == Array(om[4..<12]) : Array(sm[4..<20]) == Array(om[4..<20]))
    if identity {
        var same = true
        for (t, ot) in zip(pf.tracks, of.tracks) {
            same = same && t.stts.elementsEqual(ot.stts, by: { $0.0 == $1.0 && $0.1 == $1.1 }) && t.sizes == ot.sizes && t.sdtp == ot.sdtp
                && t.cslg == ot.cslg && t.stss == ot.stss
                && (t.ctts ?? []).elementsEqual(ot.ctts ?? [], by: { $0.0 == $1.0 && $0.1 == $1.1 })
                && t.stsc.elementsEqual(ot.stsc, by: { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 })
        }
        check("identity trim reproduces every sample table exactly", same)
    }
    return ok
}

// MARK: Apple-side check (what QuickTime / Final Cut will see)

func appleCheck(path: String, srcPath: String, expected: Double, log: (String) -> Void) async -> Bool {
    log("APPLE CHECK (AVFoundation opens and decodes the result)")
    var ok = true
    func check(_ name: String, _ cond: Bool, _ detail: String = "") {
        log("  \(cond ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
        if !cond { ok = false }
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let src = AVURLAsset(url: URL(fileURLWithPath: srcPath))
    do {
        let dur = try await asset.load(.duration).seconds
        check("opens, duration as expected", abs(dur - expected) < 0.1, String(format: "got %.3f s, expected %.3f s", dur, expected))
        let nv = try await asset.loadTracks(withMediaType: .video).count
        let na = try await asset.loadTracks(withMediaType: .audio).count
        let sv = try await src.loadTracks(withMediaType: .video).count
        let sa = try await src.loadTracks(withMediaType: .audio).count
        check("video and audio track counts kept", nv == sv && na == sa, "video \(sv)->\(nv), audio \(sa)->\(na)")
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 320, height: 320)
        var decoded = 0
        for t in [0.0, max(0, dur - 0.1)] {
            if let _ = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { decoded += 1 }
        }
        check("first and last frames decode", decoded == 2, "\(decoded) of 2")
    } catch {
        check("AVFoundation opens the file", false, "\(error)")
    }
    return ok
}

// MARK: command: ctrim

func runContainerTrim(_ argv: [String]) async {
    var srcArg: String?
    var cutStart = 0.0, cutEnd = 0.0
    var from: Double?, to: Double?
    var outArg: String?
    var dry = false
    var i = 0
    while i < argv.count {
        let a = argv[i]
        func next() -> String { i += 1; return i < argv.count ? argv[i] : "" }
        switch a {
        case "--cut-start": cutStart = Double(next()) ?? 0
        case "--cut-end": cutEnd = Double(next()) ?? 0
        case "--from": from = Double(next())
        case "--to": to = Double(next())
        case "--out": outArg = next()
        case "--dry": dry = true
        default: if srcArg == nil { srcArg = a }
        }
        i += 1
    }
    guard let srcPath = srcArg else {
        print("usage: spike ctrim <clip> [--cut-start S --cut-end E | --from S --to E] [--out FILE] [--dry]")
        return
    }
    let srcURL = URL(fileURLWithPath: srcPath).standardizedFileURL
    let outURL: URL
    if let o = outArg { outURL = URL(fileURLWithPath: o).standardizedFileURL }
    else {
        let dir = srcURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spike-output").appendingPathComponent("trims-swift")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outURL = dir.appendingPathComponent(srcURL.deletingPathExtension().lastPathComponent + "_trim." + srcURL.pathExtension)
    }
    var lines: [String] = []
    func log(_ s: String) { print(s); lines.append(s) }
    let t0 = Date()
    do {
        let r = try containerTrim(src: srcURL.path, out: outURL.path, from: from, to: to,
                                  cutStart: cutStart, cutEnd: cutEnd, dry: dry, log: log)
        if dry { return }
        log(String(format: "Trim and verify took %.2f s", Date().timeIntervalSince(t0)))
        var all = r.ok
        if r.ok { all = await appleCheck(path: r.outPath, srcPath: srcURL.path, expected: r.expectedSeconds, log: log) && all }
        log(all ? "ALL CHECKS PASSED" : "SOME CHECKS FAILED")
        try? lines.joined(separator: "\n").write(toFile: r.outPath + ".verify.txt", atomically: true, encoding: .utf8)
    } catch {
        print("UNSUPPORTED/ERROR: \(error)")
    }
}
