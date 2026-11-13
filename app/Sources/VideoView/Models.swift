import Foundation
import SwiftUI

struct ClipRow: Identifiable, Hashable {
    var path: String
    var cid: String          // content id (size + partial hash). Moved or renamed copies share thumbnails.
    var dir: String
    var name: String
    var size: Int64
    var mtime: Double
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var fps: Double = 0
    var codec: String = ""
    var created: Double = 0  // 0 = unknown
    var camera: String = ""
    var status: Int = 0      // 0 pending, 1 ready, 2 failed

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var sortDate: Double { created > 0 ? created : mtime }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name"
    case date = "Date"
    case duration = "Duration"
    case size = "Size"
    case camera = "Camera"
    var id: String { rawValue }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case minimal = "Minimal"
    case info = "Info"
    var id: String { rawValue }
}

extension Color {
    static let steel = Color(red: 78/255, green: 94/255, blue: 64/255)
}

func formatDuration(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "" }
    let t = Int(s.rounded())
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func resolutionLabel(_ w: Int, _ h: Int) -> String {
    let long = max(w, h)
    switch long {
    case 7000...: return "8K"
    case 3600...: return "4K"
    case 2500...: return "2.7K"
    case 1800...: return "1080p"
    case 1200...: return "720p"
    case 1...: return "\(w)x\(h)"
    default: return ""
    }
}

extension ClipRow {
    var bitrateMbps: Double? {
        guard duration > 0, size > 0 else { return nil }
        return Double(size) * 8 / duration / 1_000_000
    }

    /// Rough estimated savings if re-encoded to HEVC. nil means not worth showing (already HEVC or too small to matter).
    var savingsLabel: String? {
        guard let mbps = bitrateMbps else { return nil }
        let isProRes = ["ap4h", "apch", "apcn", "apco", "aprn", "ap4x"].contains(codec)
        let isHEVC   = ["hvc1", "hev1"].contains(codec)
        let isH264   = codec == "avc1"
        if isHEVC { return nil }
        if isProRes { return "~80% smaller as HEVC" }
        if isH264 {
            if mbps >= 50 { return "~60% smaller as HEVC" }
            if mbps >= 20 { return "~50% smaller as HEVC" }
            if mbps >= 8  { return "~40% smaller as HEVC" }
        }
        return nil
    }
}

func formatBitrate(_ mbps: Double) -> String {
    mbps >= 1 ? String(format: "%.0f Mb/s", mbps) : String(format: "%.1f Mb/s", mbps)
}

// MARK: - Flag colors

enum FlagColor: Int, CaseIterable, Identifiable, Hashable {
    case orange = 1, red = 2, green = 3, blue = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .orange: "Orange"
        case .red:    "Red"
        case .green:  "Green"
        case .blue:   "Blue"
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .orange: .orange
        case .red:    .red
        case .green:  .green
        case .blue:   .blue
        }
    }
}

enum FlagFilter: Hashable {
    case off, any, color(FlagColor)
}

enum DuplicateFilter: Hashable {
    case off, exact, similar, any
}

enum MediaKind { case video, image, audio }

extension ClipRow {
    var mediaKind: MediaKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if Indexer.imageExts.contains(ext) { return .image }
        if Indexer.audioExts.contains(ext) { return .audio }
        return .video
    }
}

// MARK: - Date formatting

func formatShotDate(_ t: Double) -> String {
    guard t > 0 else { return "" }
    let d = Date(timeIntervalSince1970: t)
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    f.dateFormat = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date())
        ? "MMM d" : "MMM d, yyyy"
    return f.string(from: d)
}

struct Place: Identifiable, Hashable {
    let name: String
    let path: String
    let icon: String
    var id: String { path }
}
