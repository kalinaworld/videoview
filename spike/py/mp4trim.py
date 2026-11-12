#!/usr/bin/env python3
"""
Video View spike, step 4: lossless container-level trim for MP4/MOV (not fragmented).

Unlike AVFoundation passthrough export, this keeps EVERY track and box (vendor uuid boxes, XML meta,
timed metadata tracks, udta, ...). It copies the selected sample bytes untouched and only rewrites the
sample tables, edit lists and durations. The cut starts at the keyframe at or before the in point and an
edit list hides the pre-roll, so players show the exact in point.

Never modifies the source. Writes <out>.partial, verifies it by re-parsing, then renames.

usage: mp4trim.py SRC OUT [--cut-start S --cut-end E | --from S --to E] [--dry] [--ffcheck]
"""
import struct, sys, os, hashlib, argparse, bisect, subprocess

class Unsupported(Exception):
    pass

def u32(b, o): return struct.unpack_from('>I', b, o)[0]
def i32(b, o): return struct.unpack_from('>i', b, o)[0]
def u64(b, o): return struct.unpack_from('>Q', b, o)[0]
def i64(b, o): return struct.unpack_from('>q', b, o)[0]

CONT = {b'moov', b'trak', b'mdia', b'minf', b'stbl', b'edts'}
REBUILT = {b'mvhd', b'tkhd', b'edts', b'elst', b'mdhd', b'stts', b'ctts', b'stss', b'stsc', b'stsz',
           b'stco', b'co64', b'sdtp', b'sbgp', b'cslg'}

class Box:
    def __init__(self, typ, payload=None, children=None):
        self.type = typ
        self.payload = payload
        self.children = children
    def bytes(self):
        body = b''.join(c.bytes() for c in self.children) if self.children is not None else self.payload
        return struct.pack('>I4s', 8 + len(body), self.type) + body
    def find(self, typ):
        for c in self.children or []:
            if c.type == typ:
                return c
        return None
    def find_all(self, typ):
        return [c for c in self.children or [] if c.type == typ]

def parse_boxes(buf, start, end):
    out = []
    o = start
    while o + 8 <= end:
        sz = u32(buf, o)
        typ = bytes(buf[o + 4:o + 8])
        hl = 8
        if sz == 1:
            sz = u64(buf, o + 8)
            hl = 16
        elif sz == 0:
            sz = end - o
        if sz < hl or o + sz > end:
            raise Unsupported('bad box size inside moov')
        if typ in CONT:
            out.append(Box(typ, children=parse_boxes(buf, o + hl, o + sz)))
        else:
            out.append(Box(typ, payload=bytes(buf[o + hl:o + sz])))
        o += sz
    return out

def top_level(f, size):
    res = []
    pos = 0
    while pos + 8 <= size:
        f.seek(pos)
        h = f.read(16)
        sz = u32(h, 0)
        typ = h[4:8]
        hl = 8
        if sz == 1:
            sz = u64(h, 8)
            hl = 16
        elif sz == 0:
            sz = size - pos
        if sz < hl:
            raise Unsupported('bad top-level box')
        res.append((typ, pos, sz, hl))
        pos += sz
    return res

def slice_runs(runs, k, e):
    out = []
    pos = 0
    for c, v in runs:
        a = max(pos, k)
        b = min(pos + c - 1, e)
        if b >= a:
            n = b - a + 1
            if out and out[-1][1] == v:
                out[-1] = (out[-1][0] + n, v)
            else:
                out.append((n, v))
        pos += c
        if pos > e:
            break
    return out

class Track:
    def __init__(self, trak):
        self.trak = trak
        tkhd = trak.find(b'tkhd')
        mdia = trak.find(b'mdia')
        mdhd = mdia.find(b'mdhd')
        minf = mdia.find(b'minf')
        stbl = minf.find(b'stbl')
        self.handler = mdia.find(b'hdlr').payload[8:12]
        p = mdhd.payload
        self.mts = u32(p, 12) if p[0] == 0 else u32(p, 20)
        p = tkhd.payload
        self.tkhd_dur = u32(p, 20) if p[0] == 0 else u64(p, 28)
        self.stts = self.ctts = self.stss = self.stsc = self.cslg = self.sdtp = None
        self.ctts_ver = 0
        self.sbgp = []
        self.vf = {}
        self.chunk_offsets = None
        self.co64 = False
        self.const_size = 0
        self.sizes = None
        self.elst = None
        edts = trak.find(b'edts')
        if edts is not None and edts.find(b'elst') is not None:
            p = edts.find(b'elst').payload
            n = u32(p, 4)
            ents = []
            for i in range(n):
                if p[0] == 0:
                    seg, mt, ri, rf = struct.unpack_from('>IihH', p, 8 + 12 * i)
                else:
                    seg, mt, ri, rf = struct.unpack_from('>QqhH', p, 8 + 20 * i)
                rate = ri + rf / 65536.0
                if mt != -1 and rate != 1.0:
                    raise Unsupported('edit list with rate != 1')
                ents.append((seg, mt))
            self.elst = ents
        for b in stbl.children:
            t = b.type
            p = b.payload
            if t in (b'stts', b'ctts', b'stss', b'stsc', b'stsz', b'stco', b'co64', b'sdtp', b'sbgp', b'cslg'):
                self.vf[t] = p[:4]
            if t == b'stts':
                n = u32(p, 4)
                self.stts = [(u32(p, 8 + 8 * i), u32(p, 12 + 8 * i)) for i in range(n)]
            elif t == b'ctts':
                self.ctts_ver = p[0]
                n = u32(p, 4)
                fmt = '>i'  # Apple writes signed offsets even in version 0
                self.ctts = [(u32(p, 8 + 8 * i), struct.unpack_from(fmt, p, 12 + 8 * i)[0]) for i in range(n)]
            elif t == b'stss':
                n = u32(p, 4)
                self.stss = list(struct.unpack_from('>%dI' % n, p, 8))
            elif t == b'stsc':
                n = u32(p, 4)
                self.stsc = [struct.unpack_from('>III', p, 8 + 12 * i) for i in range(n)]
            elif t == b'stsz':
                self.const_size = u32(p, 4)
                n = u32(p, 8)
                self.n = n
                self.sizes = [self.const_size] * n if self.const_size else list(struct.unpack_from('>%dI' % n, p, 12))
            elif t == b'stco':
                n = u32(p, 4)
                self.chunk_offsets = list(struct.unpack_from('>%dI' % n, p, 8))
            elif t == b'co64':
                n = u32(p, 4)
                self.chunk_offsets = list(struct.unpack_from('>%dQ' % n, p, 8))
                self.co64 = True
            elif t == b'sdtp':
                self.sdtp = p[4:]
            elif t == b'sbgp':
                hl = 12 if p[0] == 1 else 8
                n = u32(p, hl)
                runs = [(u32(p, hl + 4 + 8 * i), u32(p, hl + 8 + 8 * i)) for i in range(n)]
                self.sbgp.append((p[:hl], runs))
            elif t == b'cslg':
                self.cslg = p
            elif t in (b'stsd', b'sgpd'):
                pass
            else:
                raise Unsupported('unsupported sample table box %r' % t)
        if self.stts is None or self.stsc is None or self.sizes is None or self.chunk_offsets is None:
            raise Unsupported('missing sample tables')
        self.dts = []
        self.deltas = []
        cur = 0
        for c, d in self.stts:
            self.dts.extend(range(cur, cur + c * d, d) if d > 0 else [cur] * c)
            self.deltas.extend([d] * c)
            cur += c * d
        self.total_media = cur
        if len(self.dts) != self.n:
            raise Unsupported('stts/stsz sample count mismatch')
        self.off = []
        if self.ctts:
            for c, v in self.ctts:
                self.off.extend([v] * c)
            if len(self.off) != self.n:
                raise Unsupported('ctts/stsz sample count mismatch')
        else:
            self.off = [0] * self.n
        self.pts = [d + o for d, o in zip(self.dts, self.off)]
        nch = len(self.chunk_offsets)
        self.spc = []
        self.sdi = []
        for idx, (first, per, s) in enumerate(self.stsc):
            nxt = self.stsc[idx + 1][0] if idx + 1 < len(self.stsc) else nch + 1
            for ch in range(first, nxt):
                self.spc.append(per)
                self.sdi.append(s)
        if len(self.spc) != nch or sum(self.spc) != self.n:
            raise Unsupported('stsc/stco/stsz mismatch')

def parse_file(path):
    size = os.path.getsize(path)
    f = open(path, 'rb')
    top = top_level(f, size)
    if any(t[0] in (b'moof', b'mfra') for t in top):
        raise Unsupported('fragmented file')
    if sum(1 for t in top if t[0] == b'mdat') != 1 or sum(1 for t in top if t[0] == b'moov') != 1:
        raise Unsupported('need exactly one moov and one mdat')
    _, pos, sz, hl = [t for t in top if t[0] == b'moov'][0]
    f.seek(pos)
    buf = f.read(sz)
    moov = Box(b'moov', children=parse_boxes(buf, hl, sz))
    tracks = [Track(t) for t in moov.find_all(b'trak')]
    return f, top, moov, tracks

def mvhd_info(moov):
    p = moov.find(b'mvhd').payload
    if p[0] == 0:
        return u32(p, 12), u32(p, 16)
    return u32(p, 20), u64(p, 24)

def clip_edits(tr, movie_ts, tin, tout):
    entries = tr.elst if tr.elst is not None else [(tr.tkhd_dur, 0)]
    pieces = []
    P = 0
    for seg, mt in entries:
        a = max(P, tin)
        b = min(P + seg, tout)
        if b > a:
            if mt == -1:
                pieces.append((b - a, -1))
            else:
                pieces.append((b - a, mt + round((a - P) * tr.mts / movie_ts)))
        P += seg
    return pieces

def plan_track(tr, movie_ts, tin, tout):
    pieces = clip_edits(tr, movie_ts, tin, tout)
    nonempty = [p for p in pieces if p[1] != -1]
    if not nonempty:
        raise Unsupported('a track has no media inside the window')
    m_first = nonempty[0][1]
    last_dur, last_mt = nonempty[-1]
    m_end = last_mt + round(last_dur * tr.mts / movie_ts)
    pts = tr.pts
    n = tr.n
    mono = all(pts[i] <= pts[i + 1] for i in range(n - 1))
    if tr.stss is not None:
        cands = [s - 1 for s in tr.stss]
        ks = [i for i in cands if pts[i] <= m_first]
        k = ks[-1] if ks else cands[0]
    elif mono:
        k = max(0, bisect.bisect_right(pts, m_first) - 1)
    else:
        k = next((i for i in range(n - 1, -1, -1) if pts[i] <= m_first), 0)
    if tr.stss is None and tr.handler == b'soun':
        k = max(0, k - 2)  # decoder priming / pre-roll (AAC needs the frames before the in point)
    if mono:
        e = bisect.bisect_left(pts, m_end) - 1
    else:
        e = next((i for i in range(n - 1, -1, -1) if pts[i] < m_end), k)
    e = max(e, k)
    base = tr.dts[k]
    new_pieces = []
    for dur, mt in pieces:
        if mt == -1:
            new_pieces.append((dur, -1))
        else:
            if mt - base < 0:
                raise Unsupported('negative media time after rebase')
            new_pieces.append((dur, mt - base))
    chunks = []
    s = 0
    for j, off in enumerate(tr.chunk_offsets):
        cnt = tr.spc[j]
        a, b = s, s + cnt - 1
        if b >= k and a <= e:
            lo, hi = max(a, k), min(b, e)
            chunks.append([off + sum(tr.sizes[a:lo]), sum(tr.sizes[lo:hi + 1]), hi - lo + 1, tr.sdi[j], 0])
        s += cnt
        if s > e:
            break
    return dict(k=k, e=e, base=base, pieces=new_pieces, m_first=m_first, chunks=chunks)

def vf_int(b4): return b4

def cslg_calc(dts, off, durs, ver):
    pts = [d + o for d, o in zip(dts, off)]
    least, greatest = min(off), max(off)
    start = min(pts)
    end = max(p + d for p, d in zip(pts, durs))
    shift = max(0, -least)
    vals = (shift, least, greatest, start, end)
    if ver == 0:
        return struct.pack('>iiiii', *vals)
    return struct.pack('>qqqqq', *vals)

def new_track_boxes(tr, plan):
    k, e = plan['k'], plan['e']
    base = plan['base']
    vf = tr.vf
    out = {}
    runs = slice_runs(tr.stts, k, e)
    out[b'stts'] = vf[b'stts'] + struct.pack('>I', len(runs)) + b''.join(struct.pack('>II', c, d) for c, d in runs)
    media_dur = sum(c * d for c, d in runs)
    if tr.ctts is not None:
        runs = slice_runs(tr.ctts, k, e)
        fmt = '>Ii'
        out[b'ctts'] = vf[b'ctts'] + struct.pack('>I', len(runs)) + b''.join(struct.pack(fmt, c, v) for c, v in runs)
    if tr.stss is not None:
        ss = [s - k for s in tr.stss if k <= s - 1 <= e]
        out[b'stss'] = vf[b'stss'] + struct.pack('>I', len(ss)) + struct.pack('>%dI' % len(ss), *ss)
    n = e - k + 1
    if tr.const_size:
        out[b'stsz'] = vf[b'stsz'] + struct.pack('>II', tr.const_size, n)
    else:
        out[b'stsz'] = vf[b'stsz'] + struct.pack('>II', 0, n) + struct.pack('>%dI' % n, *tr.sizes[k:e + 1])
    ents = []
    for ci, ch in enumerate(plan['chunks']):
        key = (ch[2], ch[3])
        if not ents or (ents[-1][1], ents[-1][2]) != key:
            ents.append((ci + 1, ch[2], ch[3]))
    out[b'stsc'] = vf[b'stsc'] + struct.pack('>I', len(ents)) + b''.join(struct.pack('>III', *x) for x in ents)
    if tr.sdtp is not None:
        out[b'sdtp'] = b'\x00\x00\x00\x00' + tr.sdtp[k:e + 1]
    out['sbgp'] = []
    for hdr, runs0 in tr.sbgp:
        runs = slice_runs(runs0, k, e)
        out['sbgp'].append(hdr + struct.pack('>I', len(runs)) + b''.join(struct.pack('>II', c, v) for c, v in runs))
    out['cslg'] = None
    if tr.cslg is not None:
        ver = tr.cslg[0]
        calc_full = cslg_calc(tr.dts, tr.off, tr.deltas, ver)
        if calc_full == tr.cslg[4:]:
            nd = [d - base for d in tr.dts[k:e + 1]]
            out['cslg'] = tr.cslg[:4] + cslg_calc(nd, tr.off[k:e + 1], tr.deltas[k:e + 1], ver)
            out['cslg_trusted'] = True
        else:
            out['cslg_trusted'] = False
    out['media_dur'] = media_dur
    return out

def elst_box(pieces):
    big = any(d >= 2 ** 32 or mt >= 2 ** 31 or mt < -1 for d, mt in pieces)
    if big:
        body = struct.pack('>II', 1 << 24, len(pieces)) + b''.join(struct.pack('>QqhH', d, mt, 1, 0) for d, mt in pieces)
    else:
        body = struct.pack('>II', 0, len(pieces)) + b''.join(struct.pack('>IihH', d, mt, 1, 0) for d, mt in pieces)
    return Box(b'elst', payload=body)

def patch_dur(payload, off_v0, off_v1, value):
    b = bytearray(payload)
    if b[0] == 0:
        struct.pack_into('>I', b, off_v0, value)
    else:
        struct.pack_into('>Q', b, off_v1, value)
    return bytes(b)

def build_moov(src_moov, tracks, plans, newtabs, movie_dur, chunk_offsets_by_track, co64):
    kids = []
    ti = 0
    for c in src_moov.children:
        if c.type == b'mvhd':
            kids.append(Box(b'mvhd', payload=patch_dur(c.payload, 16, 24, movie_dur)))
        elif c.type == b'trak':
            tr, plan, nt = tracks[ti], plans[ti], newtabs[ti]
            kids.append(build_trak(c, tr, plan, nt, chunk_offsets_by_track[ti], co64))
            ti += 1
        else:
            kids.append(c)
    return Box(b'moov', children=kids)

def build_trak(trak, tr, plan, nt, offsets, co64):
    total = sum(d for d, _ in plan['pieces'])
    kids = []
    had_edts = trak.find(b'edts') is not None
    new_edts = Box(b'edts', children=[elst_box(plan['pieces'])])
    for c in trak.children:
        if c.type == b'tkhd':
            kids.append(Box(b'tkhd', payload=patch_dur(c.payload, 20, 28, total)))
        elif c.type == b'edts':
            kids.append(new_edts)
        elif c.type == b'mdia':
            if not had_edts:
                kids.append(new_edts)
            kids.append(build_mdia(c, tr, plan, nt, offsets, co64))
        else:
            kids.append(c)
    return Box(b'trak', children=kids)

def build_mdia(mdia, tr, plan, nt, offsets, co64):
    kids = []
    for c in mdia.children:
        if c.type == b'mdhd':
            kids.append(Box(b'mdhd', payload=patch_dur(c.payload, 16, 24, nt['media_dur'])))
        elif c.type == b'minf':
            mk = []
            for m in c.children:
                if m.type == b'stbl':
                    mk.append(build_stbl(m, tr, nt, offsets, co64))
                else:
                    mk.append(m)
            kids.append(Box(b'minf', children=mk))
        else:
            kids.append(c)
    return Box(b'mdia', children=kids)

def build_stbl(stbl, tr, nt, offsets, co64):
    kids = []
    sb = list(nt['sbgp'])
    for c in stbl.children:
        t = c.type
        if t in (b'stts', b'ctts', b'stss', b'stsc', b'stsz', b'sdtp'):
            kids.append(Box(t, payload=nt[t]))
        elif t == b'sbgp':
            kids.append(Box(t, payload=sb.pop(0)))
        elif t == b'cslg':
            if nt['cslg'] is not None:
                kids.append(Box(t, payload=nt['cslg']))
        elif t in (b'stco', b'co64'):
            vf = tr.vf[t]
            if co64:
                kids.append(Box(b'co64', payload=vf + struct.pack('>I', len(offsets)) + struct.pack('>%dQ' % len(offsets), *offsets)))
            else:
                kids.append(Box(b'stco', payload=vf + struct.pack('>I', len(offsets)) + struct.pack('>%dI' % len(offsets), *offsets)))
        else:
            kids.append(c)
    return Box(b'stbl', children=kids)

def raw_map(box_children, path, out):
    counts = {}
    for c in box_children:
        key = path + '/' + c.type.decode('latin1')
        idx = counts.get(key, 0)
        counts[key] = idx + 1
        if c.type in CONT:
            raw_map(c.children, key + '#%d' % idx, out)
        elif c.type not in REBUILT:
            out[key + '#%d' % idx] = c.bytes()

def sample_digest(tr, f, lo, hi):
    h = hashlib.sha256()
    s = 0
    for j, off in enumerate(tr.chunk_offsets):
        cnt = tr.spc[j]
        a, b = s, s + cnt - 1
        if b >= lo and a <= hi:
            l, r = max(a, lo), min(b, hi)
            start = off + sum(tr.sizes[a:l])
            length = sum(tr.sizes[l:r + 1])
            f.seek(start)
            while length > 0:
                piece = f.read(min(length, 8 << 20))
                if not piece:
                    raise RuntimeError('short read')
                h.update(piece)
                length -= len(piece)
        s += cnt
        if s > hi:
            break
    return h.hexdigest()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('out')
    ap.add_argument('--cut-start', type=float, default=0.0)
    ap.add_argument('--cut-end', type=float, default=0.0)
    ap.add_argument('--from', dest='tfrom', type=float)
    ap.add_argument('--to', dest='tto', type=float)
    ap.add_argument('--dry', action='store_true')
    ap.add_argument('--ffcheck', action='store_true')
    a = ap.parse_args()

    src = os.path.abspath(a.src)
    out = os.path.abspath(a.out)
    if src == out:
        sys.exit('Refusing: output is the source file')
    if os.path.exists(out):
        sys.exit('Refusing: output exists: ' + out)

    sf, top, moov, tracks = parse_file(src)
    movie_ts, movie_dur0 = mvhd_info(moov)
    total_sec = movie_dur0 / movie_ts
    tin_s = a.tfrom if a.tfrom is not None else a.cut_start
    tout_s = a.tto if a.tto is not None else total_sec - a.cut_end
    if not (0 <= tin_s < tout_s <= total_sec + 0.01):
        sys.exit('Bad range %.3f to %.3f (clip is %.3f s)' % (tin_s, tout_s, total_sec))
    tin, tout = round(tin_s * movie_ts), round(tout_s * movie_ts)
    print('Source: %s  (%.2f s, %d tracks)' % (os.path.basename(src), total_sec, len(tracks)))
    print('Window: %.3f to %.3f s (keeps %.3f s)' % (tin_s, tout_s, tout_s - tin_s))

    plans = [plan_track(t, movie_ts, tin, tout) for t in tracks]
    newtabs = [new_track_boxes(t, p) for t, p in zip(tracks, plans)]
    for i, (t, p) in enumerate(zip(tracks, plans)):
        print('  track %d %s: samples %d..%d of %d, starts %.3f s before the in point (hidden by edit list)%s' % (
            i, t.handler.decode('latin1'), p['k'], p['e'], t.n,
            (p['m_first'] - t.dts[p['k']]) / t.mts,
            '' if newtabs[i].get('cslg_trusted', True) else '  [cslg formula not trusted, box dropped]'))
    movie_dur = max(sum(d for d, _ in p['pieces']) for p in plans)

    sizes_src = os.path.getsize(src)
    est_total = sum(c[1] for p in plans for c in p['chunks']) + 1_000_000
    co64 = any(t.co64 for t in tracks) or est_total >= 2 ** 32 - 1
    all_chunks = sorted(((c[0], ti, ci) for ti, p in enumerate(plans) for ci, c in enumerate(p['chunks'])))
    total_data = sum(c[1] for p in plans for c in p['chunks'])
    mdat_hl = 16 if total_data + 8 >= 2 ** 32 else 8

    def offsets_for(base_off):
        pos = base_off
        res = [[0] * len(p['chunks']) for p in plans]
        for so, ti, ci in all_chunks:
            res[ti][ci] = pos
            pos += plans[ti]['chunks'][ci][1]
        return res

    dummy = [[0] * len(p['chunks']) for p in plans]
    moov_size = len(build_moov(moov, tracks, plans, newtabs, movie_dur, dummy, co64).bytes())
    segments = []
    pos = 0
    mdat_start = None
    for typ, off, sz, hl in top:
        if typ == b'mdat':
            mdat_start = pos + mdat_hl
            segments.append(('mdat', pos))
            pos += mdat_hl + total_data
        elif typ == b'moov':
            segments.append(('moov', pos))
            pos += moov_size
        else:
            if sz > (64 << 20):
                raise Unsupported('large non-mdat top-level box %r' % typ)
            sf.seek(off)
            segments.append(('raw', sf.read(sz)))
            pos += sz
    final_size = pos
    offs = offsets_for(mdat_start)
    moov_bytes = build_moov(moov, tracks, plans, newtabs, movie_dur, offs, co64).bytes()
    assert len(moov_bytes) == moov_size
    print('Output will be %.1f MB (source %.1f MB)' % (final_size / 1048576, sizes_src / 1048576))
    if a.dry:
        return

    part = out + '.partial'
    with open(part, 'xb') as o:
        for seg in segments:
            if seg[0] == 'raw':
                o.write(seg[1])
            elif seg[0] == 'moov':
                o.write(moov_bytes)
            else:
                if mdat_hl == 8:
                    o.write(struct.pack('>I4s', 8 + total_data, b'mdat'))
                else:
                    o.write(struct.pack('>I4sQ', 1, b'mdat', 16 + total_data))
                for so, ti, ci in all_chunks:
                    length = plans[ti]['chunks'][ci][1]
                    sf.seek(so)
                    while length > 0:
                        piece = sf.read(min(length, 8 << 20))
                        if not piece:
                            raise RuntimeError('short read from source')
                        o.write(piece)
                        length -= len(piece)
        o.flush()
        os.fsync(o.fileno())

    ok = verify(src, part, sf, top, moov, tracks, plans, tin == 0 and tout >= movie_dur0)
    if not ok:
        os.rename(part, out + '.FAILED')
        sys.exit('VERIFICATION FAILED. Output kept as ' + out + '.FAILED')
    os.rename(part, out)
    print('Wrote', out)
    if a.ffcheck:
        ffcheck(out, tout_s - tin_s)

def verify(src, part, sf, top, moov, tracks, plans, identity):
    print('VERIFICATION (re-parses the new file independently)')
    ok = True
    def check(name, cond, detail=''):
        nonlocal ok
        print('  %s  %s%s' % ('PASS' if cond else 'FAIL', name, ('  [' + detail + ']') if detail else ''))
        ok = ok and cond
    of, otop, omoov, otracks = parse_file(part)
    check('same number of tracks', len(otracks) == len(tracks), '%d' % len(otracks))
    if len(otracks) != len(tracks):
        return False
    for i, (t, p, ot) in enumerate(zip(tracks, plans, otracks)):
        k, e = p['k'], p['e']
        n = e - k + 1
        base = p['base']
        good = (ot.n == n and ot.sizes == t.sizes[k:e + 1]
                and ot.dts == [d - base for d in t.dts[k:e + 1]]
                and ot.off == t.off[k:e + 1])
        if t.stss is not None:
            sset = [s - k for s in t.stss if k <= s - 1 <= e]
            good = good and ot.stss == sset
        check('track %d sample tables (sizes, timing, keyframes)' % i, good, '%d samples' % ot.n)
        d1 = sample_digest(t, sf, k, e)
        d2 = sample_digest(ot, of, 0, n - 1)
        check('track %d sample bytes identical to source' % i, d1 == d2, d1[:12])
    a, b = {}, {}
    raw_map(moov.children, '/moov', a)
    raw_map(omoov.children, '/moov', b)
    check('all vendor and metadata boxes inside moov byte-identical', a == b, '%d boxes' % len(a))
    top_ok = True
    for (typ, off, sz, hl) in top:
        if typ in (b'mdat', b'moov'):
            continue
        sf.seek(off)
        x = sf.read(sz)
        found = False
        for (t2, o2, s2, h2) in otop:
            if t2 == typ and s2 == sz:
                of.seek(o2)
                if of.read(s2) == x:
                    found = True
                    break
        top_ok = top_ok and found
    check('all other top-level boxes byte-identical (uuid, meta, ftyp...)', top_ok)
    check('top-level box order kept', [t[0] for t in top] == [t[0] for t in otop])
    sp, op_ = mvhd_info(moov), mvhd_info(omoov)
    sm, om = moov.find(b'mvhd').payload, omoov.find(b'mvhd').payload
    check('container creation and modification time kept', sm[4:12] == om[4:12] if sm[0] == 0 else sm[4:20] == om[4:20])
    if identity:
        same = True
        for t, ot in zip(tracks, otracks):
            same = same and (t.stts == ot.stts and t.ctts == ot.ctts and t.stss == ot.stss and t.sizes == ot.sizes
                             and t.stsc == ot.stsc and t.sdtp == ot.sdtp and t.cslg == ot.cslg and t.sbgp == ot.sbgp)
        check('identity trim reproduces every sample table exactly', same)
    return ok

def ffcheck(path, expect_sec):
    print('FFMPEG CHECK (independent decoder)')
    r = subprocess.run(['ffprobe', '-v', 'error', '-count_frames', '-select_streams', 'v:0',
                        '-show_entries', 'stream=nb_read_frames,r_frame_rate,duration', '-of', 'default=nw=1', path],
                       capture_output=True, text=True)
    print(r.stdout.strip(), r.stderr.strip()[:300])
    r = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-f', 'null', '-'], capture_output=True, text=True)
    print('  decode errors:', 'none' if not r.stderr.strip() else r.stderr.strip()[:500])

if __name__ == '__main__':
    try:
        main()
    except Unsupported as ex:
        sys.exit('UNSUPPORTED: %s (the app would fall back or refuse)' % ex)
