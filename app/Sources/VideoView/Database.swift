import Foundation
import SQLite3

/// Small SQLite wrapper. One connection in WAL mode, guarded by a lock. The index is rebuildable from the files.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct Row {
        let st: OpaquePointer?
        func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(st, i) else { return "" }
            return String(cString: c)
        }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(st, i)) }
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(st, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(st, i) }
    }

    init(path: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else { throw NSError(domain: "VideoView.DB", code: Int(rc)) }
        run("PRAGMA journal_mode=WAL")
        run("PRAGMA synchronous=NORMAL")
        run("""
        CREATE TABLE IF NOT EXISTS clips(
            path TEXT PRIMARY KEY, cid TEXT, dir TEXT, name TEXT, size INTEGER, mtime REAL,
            duration REAL, width INTEGER, height INTEGER, fps REAL, codec TEXT, created REAL,
            camera TEXT, status INTEGER)
        """)
        run("CREATE INDEX IF NOT EXISTS clips_dir ON clips(dir)")
        run("CREATE INDEX IF NOT EXISTS clips_cid ON clips(cid)")
        run("CREATE TABLE IF NOT EXISTS dirs(path TEXT PRIMARY KEY, parent TEXT)")
        run("CREATE INDEX IF NOT EXISTS dirs_parent ON dirs(parent)")
        run("CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY, added REAL)")
        // Metadata and flags are keyed by content id, so they follow a file when it is moved or renamed.
        run("CREATE TABLE IF NOT EXISTS meta(cid TEXT PRIMARY KEY, duration REAL, width INTEGER, height INTEGER, fps REAL, codec TEXT, created REAL, camera TEXT)")
        run("CREATE TABLE IF NOT EXISTS flags(cid TEXT PRIMARY KEY, color INTEGER NOT NULL DEFAULT 1)")
        let ver = rows("PRAGMA user_version", [], { $0.int(0) }).first ?? 0
        if ver < 1 {
            run("INSERT OR IGNORE INTO meta SELECT cid,duration,width,height,fps,codec,created,camera FROM clips WHERE status=1 AND camera!=''")
            run("UPDATE clips SET status=0 WHERE camera=''")
            run("PRAGMA user_version=1")
        }
        if ver < 2 {
            // Add color column to existing flags tables (new tables already have it from CREATE above)
            run("ALTER TABLE flags ADD COLUMN color INTEGER NOT NULL DEFAULT 1")
            run("PRAGMA user_version=2")
        }
    }

    private func bind(_ st: OpaquePointer?, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            guard let a = a else { sqlite3_bind_null(st, idx); continue }
            switch a {
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, transient)
            default: sqlite3_bind_null(st, idx)
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Any?] = []) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            NSLog("VideoView SQL prepare failed: %@", String(cString: sqlite3_errmsg(db)))
            return false
        }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        let rc = sqlite3_step(st)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    func rows<T>(_ sql: String, _ args: [Any?] = [], _ map: (Row) -> T) -> [T] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            NSLog("VideoView SQL prepare failed: %@", String(cString: sqlite3_errmsg(db)))
            return []
        }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(map(Row(st: st))) }
        return out
    }

    // MARK: clips

    private static let clipCols = "path,cid,dir,name,size,mtime,duration,width,height,fps,codec,created,camera,status"

    private func mapClip(_ r: Row) -> ClipRow {
        ClipRow(path: r.text(0), cid: r.text(1), dir: r.text(2), name: r.text(3), size: r.int64(4), mtime: r.double(5),
                duration: r.double(6), width: r.int(7), height: r.int(8), fps: r.double(9), codec: r.text(10),
                created: r.double(11), camera: r.text(12), status: r.int(13))
    }

    func upsertClip(_ c: ClipRow) {
        run("INSERT OR REPLACE INTO clips(\(Self.clipCols)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            [c.path, c.cid, c.dir, c.name, c.size, c.mtime, c.duration, c.width, c.height, c.fps, c.codec,
             c.created, c.camera, c.status])
        if c.status == 1 {
            run("INSERT OR REPLACE INTO meta(cid,duration,width,height,fps,codec,created,camera) VALUES(?,?,?,?,?,?,?,?)",
                [c.cid, c.duration, c.width, c.height, c.fps, c.codec, c.created, c.camera])
        }
    }

    func clips(inDir dir: String) -> [ClipRow] {
        rows("SELECT \(Self.clipCols) FROM clips WHERE dir=?", [dir], mapClip)
    }

    /// Saved metadata for the same content (a moved, renamed or copied file), so it is not read again.
    func readyClip(cid: String) -> ClipRow? {
        rows("SELECT duration,width,height,fps,codec,created,camera FROM meta WHERE cid=?", [cid]) { r in
            ClipRow(path: "", cid: cid, dir: "", name: "", size: 0, mtime: 0, duration: r.double(0), width: r.int(1),
                    height: r.int(2), fps: r.double(3), codec: r.text(4), created: r.double(5), camera: r.text(6), status: 1)
        }.first
    }

    // MARK: flags

    func flagColors() -> [String: FlagColor] {
        var out: [String: FlagColor] = [:]
        for (cid, raw) in rows("SELECT cid, color FROM flags", [], { ($0.text(0), $0.int(1)) }) {
            out[cid] = FlagColor(rawValue: raw) ?? .orange
        }
        return out
    }

    func setFlag(_ cid: String, _ color: FlagColor?) {
        if let color {
            run("INSERT OR REPLACE INTO flags(cid, color) VALUES(?, ?)", [cid, color.rawValue])
        } else {
            run("DELETE FROM flags WHERE cid=?", [cid])
        }
    }

    func deleteClips(inDir dir: String, keeping: Set<String>) {
        for p in rows("SELECT path FROM clips WHERE dir=?", [dir], { $0.text(0) }) where !keeping.contains(p) {
            run("DELETE FROM clips WHERE path=?", [p])
        }
    }

    func removeClip(path: String) { run("DELETE FROM clips WHERE path=?", [path]) }

    func resetStatuses() { run("UPDATE clips SET status=0") }

    // MARK: dirs

    func upsertDir(_ path: String, parent: String) {
        run("INSERT OR REPLACE INTO dirs(path,parent) VALUES(?,?)", [path, parent])
    }

    func subdirs(of parent: String) -> [String] {
        rows("SELECT path FROM dirs WHERE parent=? ORDER BY path", [parent], { $0.text(0) })
    }

    func deleteDirs(parent: String, keeping: Set<String>) {
        for p in subdirs(of: parent) where !keeping.contains(p) { run("DELETE FROM dirs WHERE path=?", [p]) }
    }

    // MARK: roots

    func roots() -> [String] {
        rows("SELECT path FROM roots ORDER BY added", [], { $0.text(0) })
    }

    func addRoot(_ path: String) {
        run("INSERT OR IGNORE INTO roots(path,added) VALUES(?,?)", [path, Date().timeIntervalSince1970])
    }

    func removeRoot(_ path: String) { run("DELETE FROM roots WHERE path=?", [path]) }
}
