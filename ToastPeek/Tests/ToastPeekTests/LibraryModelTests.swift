import XCTest

final class LibraryModelTests: XCTestCase {
    func testDownloadRecordMediaAndHost() {
        let r = DownloadRecord(fileName: "photo.JPG", urlString: "https://www.example.com/a.jpg", fullPath: "/tmp/photo.JPG")
        XCTAssertTrue(r.isMedia)
        XCTAssertEqual(r.sourceHost, "example.com")
        XCTAssertFalse(DownloadRecord(fileName: "app.dmg", urlString: "", fullPath: "/tmp/app.dmg").isMedia)
    }

    func testOlderStateFilesStillLoad() throws {
        // Written before the Library and site controls, with the removed
        // Easels/Notes keys still present: unknown keys are ignored.
        let sid = UUID().uuidString
        let json = "{\"spaces\":[{\"id\":\"" + sid + "\",\"name\":\"P\",\"icon\":\"house\",\"colorHex\":\"#7C6FF0\"}],"
            + "\"currentSpaceID\":\"" + sid + "\",\"tabs\":[],\"boosts\":[],\"history\":[],\"archiveAfterHours\":12,"
            + "\"easels\":[{\"id\":\"" + UUID().uuidString + "\",\"spaceID\":\"" + sid + "\",\"title\":\"E\"}],\"notes\":[]}"
        let s = try XCTUnwrap(StateFile.decode(Data(json.utf8)))
        XCTAssertNil(s.downloadRecords)
        XCTAssertNil(s.blockerExemptHosts)
        XCTAssertNil(s.externalLinksInPeek)
    }
}
