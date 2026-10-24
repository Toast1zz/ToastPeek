import XCTest

final class ImportAndBoostTests: XCTestCase {
    func testBoostMatchesSiteAndSubdomainsOnly() {
        let b = Boost(name: "x", hostPattern: " GitHub.com ")
        XCTAssertTrue(b.matches(host: "github.com"))
        XCTAssertTrue(b.matches(host: "gist.GITHUB.com"))
        XCTAssertFalse(b.matches(host: "notgithub.com"))
        XCTAssertFalse(b.matches(host: "github.com.evil.example"))
        var off = b
        off.isEnabled = false
        XCTAssertFalse(off.matches(host: "github.com"))
        XCTAssertFalse(Boost(name: "empty", hostPattern: "").matches(host: "github.com"))
    }

    func testSearchQueryEncoding() throws {
        let url = try XCTUnwrap(URLResolver.searchURL(for: "a&b=c #1 +x", engine: .google))
        let item = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }
        XCTAssertEqual(item?.value, "a&b=c #1 +x")
    }
}
