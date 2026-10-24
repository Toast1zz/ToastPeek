import XCTest

final class PageOpenPolicyTests: XCTestCase {
    func testWebAddressesAreAllowed() {
        for s in ["https://example.com", "http://example.com/a?b=c", "about:blank", "", "HTTPS://EXAMPLE.COM",
                  "blob:https://example.com/0b1d"] {
            XCTAssertTrue(PageOpenPolicy.isAllowedTarget(s), s)
        }
    }

    func testOtherSchemesAreBlocked() {
        for s in ["file:///etc/passwd", "FILE:///Users", "chrome://settings", "chrome://version", "devtools://devtools",
                  "javascript:alert(1)", "data:text/html,<b>x</b>", "view-source:https://example.com",
                  "blob:null/1234", "about:settings", "https://", "mailto:a@b.c"] {
            XCTAssertFalse(PageOpenPolicy.isAllowedTarget(s), s)
        }
    }

    func testNeedsAUserGesture() {
        var limiter = OpenRateLimiter()
        XCTAssertEqual(PageOpenPolicy.verdict(for: "https://ad.example", userGesture: false, limiter: &limiter), .blockedNoGesture)
        XCTAssertEqual(PageOpenPolicy.verdict(for: "https://ok.example", userGesture: true, limiter: &limiter), .allow)
    }

    func testSchemeCheckComesFirst() {
        var limiter = OpenRateLimiter()
        XCTAssertEqual(PageOpenPolicy.verdict(for: "file:///", userGesture: true, limiter: &limiter), .blockedScheme)
    }

    func testRateLimit() {
        var limiter = OpenRateLimiter(limit: 5, window: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<5 {
            XCTAssertEqual(PageOpenPolicy.verdict(for: "https://x.example/\(i)", userGesture: true,
                                                  limiter: &limiter, now: t0), .allow)
        }
        XCTAssertEqual(PageOpenPolicy.verdict(for: "https://x.example/6", userGesture: true,
                                              limiter: &limiter, now: t0.addingTimeInterval(1)), .blockedRateLimit)
        XCTAssertEqual(PageOpenPolicy.verdict(for: "https://x.example/7", userGesture: true,
                                              limiter: &limiter, now: t0.addingTimeInterval(10.5)), .allow)
    }
}
