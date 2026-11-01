import Foundation

/// Horizontal split panes keep usable page widths. A smaller viewport scrolls
/// the strip instead of silently clipping secondary panes outside the window.
enum SplitLayout {
    static func contentWidth(viewport: CGFloat, count: Int, minimum: CGFloat = 200,
                             gutter: CGFloat = 8) -> CGFloat {
        guard count > 0 else { return max(0, viewport) }
        return max(max(0, viewport), CGFloat(count) * minimum + CGFloat(count - 1) * gutter)
    }

    static func widths(viewport: CGFloat, fractions: [CGFloat], minimum: CGFloat = 200,
                       gutter: CGFloat = 8) -> [CGFloat] {
        guard !fractions.isEmpty else { return [] }
        let total = contentWidth(viewport: viewport, count: fractions.count, minimum: minimum, gutter: gutter)
        var remaining = total - CGFloat(fractions.count - 1) * gutter
        var pending = Array(fractions.indices)
        var widths = Array(repeating: CGFloat(0), count: fractions.count)
        let weights = fractions.map { $0.isFinite ? max(0, $0) : 0 }
        // Clamp undersized panes, then redistribute only the remaining space.
        // Independent max(minimum, fraction * total) would exceed the container.
        while !pending.isEmpty {
            let sum = pending.reduce(CGFloat(0)) { $0 + weights[$1] }
            let candidates = pending.map { i in
                (i, sum > 0 ? remaining * weights[i] / sum : remaining / CGFloat(pending.count))
            }
            let small = candidates.filter { $0.1 < minimum }
            if small.isEmpty {
                for (i, value) in candidates { widths[i] = value }
                break
            }
            let fixed = Set(small.map(\.0))
            for i in fixed { widths[i] = minimum; remaining -= minimum }
            pending.removeAll { fixed.contains($0) }
        }
        return widths
    }
}
