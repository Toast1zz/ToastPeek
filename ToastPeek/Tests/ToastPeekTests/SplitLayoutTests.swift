import XCTest

final class SplitLayoutTests: XCTestCase {
    func testEveryPaneRemainsReachableAtMinimumWindowAndWideSidebar() {
        // 640pt window minus the widest sidebar and card padding.
        let viewport: CGFloat = 212
        for count in 2...4 {
            let widths = SplitLayout.widths(viewport: viewport, fractions: Array(repeating: 1, count: count))
            let strip = SplitLayout.contentWidth(viewport: viewport, count: count)
            XCTAssertGreaterThan(strip, viewport, "Small viewports must expose a scrollable strip")
            XCTAssertTrue(widths.allSatisfy { $0 >= 200 })
            XCTAssertEqual(widths.reduce(0, +) + CGFloat(count - 1) * 8, strip, accuracy: 0.001)
        }
    }

    func testSkewedWidthsNeverExpandPastScrollableContainer() {
        for viewport: CGFloat in [640, 800, 1200, 1800] {
            for fractions: [CGFloat] in [[0.99, 0.01], [0.8, 0.1, 0.1], [0.4, 0.3, 0.2, 0.1], [0, 0, 0, 0]] {
                let widths = SplitLayout.widths(viewport: viewport, fractions: fractions)
                XCTAssertEqual(widths.count, fractions.count)
                XCTAssertTrue(widths.allSatisfy { $0 >= 200 && $0.isFinite })
                XCTAssertEqual(widths.reduce(0, +) + CGFloat(widths.count - 1) * 8,
                               SplitLayout.contentWidth(viewport: viewport, count: widths.count), accuracy: 0.001)
            }
        }
    }

    func testSinglePaneAndInvalidWeightsRemainFinite() {
        XCTAssertEqual(SplitLayout.widths(viewport: 800, fractions: [1]), [800])
        let widths = SplitLayout.widths(viewport: 1000, fractions: [.nan, -.infinity, -1, 1])
        XCTAssertTrue(widths.allSatisfy { $0.isFinite && $0 >= 200 })
        XCTAssertEqual(widths.reduce(0, +) + 24, 1000, accuracy: 0.001)
        XCTAssertEqual(SplitLayout.widths(viewport: 1000, fractions: []), [])
    }
}
