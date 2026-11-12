import SwiftUI

extension ClipRow {
    /// Width / height of the tile. Dimensions are already rotation corrected. Clamped so odd shapes stay sane.
    var tileAspect: Double {
        guard width > 0, height > 0 else { return 16.0 / 9.0 }
        return min(max(Double(width) / Double(height), 0.5), 2.4)
    }
}

struct TileItem: Identifiable {
    enum Kind { case folder(String), clip(ClipRow) }
    let kind: Kind
    let aspect: Double
    var id: String {
        switch kind {
        case .folder(let p): return "d|" + p
        case .clip(let c): return "c|" + c.path
        }
    }
}

struct TileRow: Identifiable {
    let items: [TileItem]
    let height: Double
    var id: String { items.first?.id ?? "empty" }
}

/// Packs tiles into rows that all share one height per row (like Google Photos), so tall and wide
/// clips sit together without gaps. Each row is scaled a little so it fills the width exactly.
func justify(_ items: [TileItem], width: Double, target: Double, spacing: Double = 16) -> [TileRow] {
    guard width > 50 else { return items.map { TileRow(items: [$0], height: target) } }
    var rows: [TileRow] = []
    var cur: [TileItem] = []
    var sum = 0.0

    func fit(_ list: [TileItem], _ s: Double) -> Double {
        (width - spacing * Double(list.count - 1)) / (target * s)
    }

    for item in items {
        cur.append(item); sum += item.aspect
        let needed = target * sum + spacing * Double(cur.count - 1)
        if needed <= width { continue }
        let scaleIn = fit(cur, sum)                       // shrink factor if we keep this item
        if cur.count == 1 {
            rows.append(TileRow(items: cur, height: min(target, width / item.aspect)))
            cur = []; sum = 0
        } else if scaleIn >= 0.85 {
            rows.append(TileRow(items: cur, height: target * scaleIn))
            cur = []; sum = 0
        } else {
            let prev = Array(cur.dropLast())
            let prevSum = sum - item.aspect
            let stretch = min(fit(prev, prevSum), 1.3)
            rows.append(TileRow(items: prev, height: target * stretch))
            cur = [item]; sum = item.aspect
        }
    }
    if !cur.isEmpty { rows.append(TileRow(items: cur, height: target)) }   // last row keeps its natural size
    return rows
}
