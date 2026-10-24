import XCTest

final class SitePermissionTests: XCTestCase {
    private let origin = "https://meet.example.com/"

    func testUnknownSiteAsks() {
        let list: [SitePermission] = []
        XCTAssertEqual(list.decision(origin: origin, kind: .media, requested: MediaPermission.camera), .ask)
    }

    func testRememberedAllowCoversOnlyThoseDevices() {
        var list: [SitePermission] = []
        list.remember(origin: origin, kind: .media, requested: MediaPermission.camera, allow: true)
        XCTAssertEqual(list.decision(origin: origin, kind: .media, requested: MediaPermission.camera), .allow)
        XCTAssertEqual(list.decision(origin: origin, kind: .media,
                                     requested: MediaPermission.camera | MediaPermission.microphone), .ask)
    }

    func testDenyWinsForAnyDeniedBit() {
        var list: [SitePermission] = []
        list.remember(origin: origin, kind: .media, requested: MediaPermission.microphone, allow: false)
        XCTAssertEqual(list.decision(origin: origin, kind: .media,
                                     requested: MediaPermission.camera | MediaPermission.microphone), .deny)
        XCTAssertEqual(list.decision(origin: origin, kind: .media, requested: MediaPermission.camera), .ask)
    }

    func testScreenAndSystemAudioAreNeverRemembered() {
        var list: [SitePermission] = []
        list.remember(origin: origin, kind: .media, requested: MediaPermission.screen | MediaPermission.systemAudio, allow: true)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list.decision(origin: origin, kind: .media, requested: MediaPermission.screen), .ask)

        list.remember(origin: origin, kind: .media, requested: MediaPermission.camera | MediaPermission.screen, allow: true)
        XCTAssertEqual(list.decision(origin: origin, kind: .media, requested: MediaPermission.camera), .allow)
        XCTAssertEqual(list.decision(origin: origin, kind: .media, requested: MediaPermission.screen), .ask)
    }

    func testMediaAndPromptBitsNeverMix() {
        var list: [SitePermission] = []
        // Bit 1 << 1 is "camera" for media and "camera pan/tilt/zoom" for prompts.
        list.remember(origin: origin, kind: .media, requested: MediaPermission.camera, allow: true)
        XCTAssertEqual(list.decision(origin: origin, kind: .prompt, requested: PromptPermission.cameraPanTiltZoom), .ask)
        list.remember(origin: origin, kind: .prompt, requested: PromptPermission.notifications, allow: false)
        XCTAssertEqual(list.decision(origin: origin, kind: .prompt, requested: PromptPermission.notifications), .deny)
        XCTAssertEqual(list.decision(origin: origin, kind: .media, requested: MediaPermission.camera), .allow)
    }

    func testChangingAnAnswerFlipsTheBit() {
        var list: [SitePermission] = []
        list.remember(origin: origin, kind: .prompt, requested: PromptPermission.geolocation, allow: false)
        list.remember(origin: origin, kind: .prompt, requested: PromptPermission.geolocation, allow: true)
        XCTAssertEqual(list.decision(origin: origin, kind: .prompt, requested: PromptPermission.geolocation), .allow)
        XCTAssertEqual(list.count, 1)
    }

    func testRecordsInTheOldFormatLoadEmpty() throws {
        let old = #"[{"origin":"https://a.example/","grantedPermissions":3,"denied":false,"updatedAt":0}]"#
        let decoded = try JSONDecoder().decode([SitePermission].self, from: Data(old.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertTrue(decoded[0].isEmpty)
        XCTAssertEqual(decoded.decision(origin: "https://a.example/", kind: .media, requested: 3), .ask)
    }

    func testRoundTrip() throws {
        var list: [SitePermission] = []
        list.remember(origin: origin, kind: .media, requested: MediaPermission.camera, allow: true)
        list.remember(origin: origin, kind: .prompt, requested: PromptPermission.notifications, allow: false)
        let back = try JSONDecoder().decode([SitePermission].self, from: JSONEncoder().encode(list))
        XCTAssertEqual(back, list)
    }

    func testFeatureNamesUseTheRightTable() {
        XCTAssertEqual(SitePermission.featureNames(kind: .prompt, mask: PromptPermission.geolocation).count, 1)
        XCTAssertEqual(SitePermission.featureNames(kind: .media, mask: MediaPermission.camera | MediaPermission.microphone).count, 2)
        XCTAssertEqual(SitePermission.featureNames(kind: .prompt, mask: 1 << 29).count, 1) // "other features"
    }
}
