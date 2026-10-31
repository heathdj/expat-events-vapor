import Foundation
import ExpatEventsAPI

/// Geometry for the admin dashboard's charts, drawn as inline SVG by the
/// Leaf templates (user's M10 decision: server-drawn SVG, no JavaScript
/// chart library). Everything here is plain arithmetic turned into
/// strings, so the templates only place shapes and tests can check the
/// numbers without a browser.
enum AdminCharts {
    struct Bar: Encodable {
        let x: String
        let y: String
        let width: String
        let height: String
        let title: String
    }

    struct Point: Encodable {
        let x: String
        let y: String
        let title: String
    }

    struct AxisLabel: Encodable {
        let x: String
        let text: String
    }

    struct Tick: Encodable {
        let y: String
        let labelY: String
        let text: String
    }

    /// The bar-and-line activity chart: events created as bars, new
    /// accounts as a line, on a shared axis.
    struct Activity: Encodable {
        let bars: [Bar]
        let points: [Point]
        let linePoints: String
        let xLabels: [AxisLabel]
        let ticks: [Tick]
        let totalAccounts: String
        let totalEvents: String
        let isFourWeeks: Bool
        let isTwelveWeeks: Bool
        let isYear: Bool
        let rangeLabel: String
    }

    static let plotLeft = 40.0
    static let plotRight = 630.0
    static let plotTop = 16.0
    static let plotBottom = 176.0

    static func activity(_ buckets: [AdminService.ActivityBucket], range: AdminService.ActivityRange) -> Activity {
        let count = max(buckets.count, 1)
        let maxValue = buckets.map { max($0.newAccounts, $0.eventsCreated) }.max() ?? 0
        let top = niceMax(maxValue)
        let slot = (plotRight - plotLeft) / Double(count)
        let barWidth = slot * 0.56
        func y(_ value: Int) -> Double {
            plotBottom - (plotBottom - plotTop) * Double(value) / Double(top)
        }
        let labelFormat = range == .year ? "MMM" : "MMM d"
        var bars: [Bar] = []
        var points: [Point] = []
        for (index, bucket) in buckets.enumerated() {
            let center = plotLeft + slot * (Double(index) + 0.5)
            let label = format(bucket.start, labelFormat)
            let barTop = y(bucket.eventsCreated)
            bars.append(Bar(
                x: fixed(center - barWidth / 2), y: fixed(barTop),
                width: fixed(barWidth), height: fixed(plotBottom - barTop),
                title: "\(label): \(bucket.eventsCreated) event\(bucket.eventsCreated == 1 ? "" : "s") created"
            ))
            points.append(Point(
                x: fixed(center), y: fixed(y(bucket.newAccounts)),
                title: "\(label): \(bucket.newAccounts) new account\(bucket.newAccounts == 1 ? "" : "s")"
            ))
        }
        // About five evenly spaced date labels, always including the last.
        let step = max(1, Int((Double(count) / 5).rounded(.up)))
        var labelIndexes = Array(stride(from: 0, to: buckets.count, by: step))
        if let last = buckets.indices.last {
            if let final = labelIndexes.last, last - final < step / 2 + 1, final != last { labelIndexes.removeLast() }
            if labelIndexes.last != last { labelIndexes.append(last) }
        }
        let xLabels = labelIndexes.map { index in
            AxisLabel(x: fixed(plotLeft + slot * (Double(index) + 0.5)), text: format(buckets[index].start, labelFormat))
        }
        let ticks = (0...4).map { i -> Tick in
            let value = top * i / 4
            let tickY = y(value)
            return Tick(y: fixed(tickY), labelY: fixed(tickY + 4), text: String(value))
        }
        return Activity(
            bars: bars,
            points: points,
            linePoints: points.map { "\($0.x),\($0.y)" }.joined(separator: " "),
            xLabels: xLabels,
            ticks: ticks,
            totalAccounts: number(buckets.reduce(0) { $0 + $1.newAccounts }),
            totalEvents: number(buckets.reduce(0) { $0 + $1.eventsCreated }),
            isFourWeeks: range == .fourWeeks,
            isTwelveWeeks: range == .twelveWeeks,
            isYear: range == .year,
            rangeLabel: range == .fourWeeks ? "last 4 weeks, by day" : range == .twelveWeeks ? "last 12 weeks, by week" : "last 12 months, by month"
        )
    }

    /// A small trend line for a headline card (viewBox 0 0 120 28).
    static func sparkline(_ values: [Int]) -> String {
        guard values.count > 1 else { return "0,24 120,24" }
        let top = Double(max(values.max() ?? 0, 1))
        let step = 120.0 / Double(values.count - 1)
        return values.enumerated().map { index, value in
            "\(fixed(step * Double(index))),\(fixed(25 - 21 * Double(value) / top))"
        }.joined(separator: " ")
    }

    struct DonutSegment: Encodable {
        let dashArray: String
        let dashOffset: String
        let colorClass: String
    }

    /// Ring segments for the plan split (r = 70).
    static func donut(_ parts: [(value: Int, colorClass: String)]) -> [DonutSegment] {
        let total = parts.reduce(0) { $0 + $1.value }
        guard total > 0 else { return [] }
        let circumference = 2 * Double.pi * 70
        var used = 0.0
        var segments: [DonutSegment] = []
        for part in parts where part.value > 0 {
            let length = circumference * Double(part.value) / Double(total)
            segments.append(DonutSegment(
                dashArray: "\(fixed(length)) \(fixed(circumference))",
                dashOffset: fixed(-used),
                colorClass: part.colorClass
            ))
            used += length
        }
        return segments
    }

    struct CategoryBar: Encodable {
        let label: String
        let count: Int
        let y: String
        let labelY: String
        let width: String
        let valueX: String
        let opacity: String
    }

    /// Horizontal bars, one row of 28 units each (viewBox width 560).
    static func categories(_ counts: [(EventCategory, Int)]) -> (bars: [CategoryBar], height: Int) {
        let top = Double(max(counts.map { $0.1 }.max() ?? 0, 1))
        let bars = counts.enumerated().map { index, entry -> CategoryBar in
            let width = max(380 * Double(entry.1) / top, 4)
            let rowY = 8 + 28 * Double(index)
            return CategoryBar(
                label: entry.0.rawValue.capitalized,
                count: entry.1,
                y: fixed(rowY),
                labelY: fixed(rowY + 12.5),
                width: fixed(width),
                valueX: fixed(96 + width + 8),
                opacity: fixed(max(1 - 0.12 * Double(index), 0.35))
            )
        }
        return (bars, 16 + 28 * counts.count)
    }

    /// The smallest "round" axis maximum (1, 2 or 5 times a power of ten,
    /// and at least 4 so the four ticks stay whole numbers) at or above
    /// `value`.
    static func niceMax(_ value: Int) -> Int {
        guard value > 4 else { return 4 }
        var magnitude = 1
        while magnitude * 10 <= value { magnitude *= 10 }
        for multiple in [1, 2, 4, 5, 8, 10] where multiple * magnitude >= value {
            let candidate = multiple * magnitude
            if candidate % 4 == 0 { return candidate }
        }
        return ((value + 3) / 4) * 4
    }

    static func fixed(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// "1,284". A fresh formatter per call (not thread-safe on Linux).
    static func number(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func format(_ date: Date, _ pattern: String) -> String {
        EventDateTag.makeFormatter(pattern, timeZone: nil).string(from: date)
    }
}
