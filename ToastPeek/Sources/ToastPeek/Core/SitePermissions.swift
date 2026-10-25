import Foundation

enum SiteOrigin {
    static func make(scheme: String, host: String, port: Int = 0) -> String {
        let scheme = scheme.lowercased()
        let rawHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let effectivePort = port > 0 ? port : scheme == "https" ? 443 : scheme == "http" ? 80 : 0
        return "\(scheme)://\(host)" + (effectivePort > 0 ? ":\(effectivePort)" : "")
    }
    static func make(_ url: URL) -> String {
        make(scheme: url.scheme ?? "", host: url.host ?? "", port: url.port ?? 0)
    }
}

/// Media permission bits (kept stable across the engine switch so
/// persisted site permissions keep working). WebTabController maps
/// WKMediaCaptureType onto them.
enum MediaPermission {
    static let microphone: UInt32 = 1 << 0
    static let camera: UInt32 = 1 << 1
    static let systemAudio: UInt32 = 1 << 2
    static let screen: UInt32 = 1 << 3
    /// Screen and system-audio capture are asked every time, like Chrome.
    static let neverRemembered: UInt32 = systemAudio | screen
}

/// Prompt permission bits; only the media set is used by the WebKit
/// permission flow.
enum PromptPermission {
    static let arSession: UInt32 = 1 << 0
    static let cameraPanTiltZoom: UInt32 = 1 << 1
    static let cameraStream: UInt32 = 1 << 2
    static let capturedSurfaceControl: UInt32 = 1 << 3
    static let clipboard: UInt32 = 1 << 4
    static let topLevelStorageAccess: UInt32 = 1 << 5
    static let diskQuota: UInt32 = 1 << 6
    static let localFonts: UInt32 = 1 << 7
    static let geolocation: UInt32 = 1 << 8
    static let handTracking: UInt32 = 1 << 9
    static let identityProvider: UInt32 = 1 << 10
    static let idleDetection: UInt32 = 1 << 11
    static let micStream: UInt32 = 1 << 12
    static let midiSysex: UInt32 = 1 << 13
    static let multipleDownloads: UInt32 = 1 << 14
    static let notifications: UInt32 = 1 << 15
    static let keyboardLock: UInt32 = 1 << 16
    static let pointerLock: UInt32 = 1 << 17
    static let protectedMediaIdentifier: UInt32 = 1 << 18
    static let registerProtocolHandler: UInt32 = 1 << 19
    static let storageAccess: UInt32 = 1 << 20
    static let vrSession: UInt32 = 1 << 21
    static let webAppInstallation: UInt32 = 1 << 22
    static let windowManagement: UInt32 = 1 << 23
    static let fileSystemAccess: UInt32 = 1 << 24
}

/// Which permission flow a request came from; the two use unrelated bit sets.
enum PermissionKind: String, Codable {
    case media, prompt
}

enum PermissionDecision: Equatable {
    case allow, deny, ask
}

/// A site's remembered answers, kept per request kind so a bit from one set
/// can never be read as a bit of the other.
struct SitePermission: Identifiable, Codable, Hashable {
    var id: String { (profileID?.uuidString ?? "legacy") + "|" + origin }
    var origin: String
    var profileID: UUID? = nil
    var mediaAllowed: UInt32 = 0
    var mediaDenied: UInt32 = 0
    var promptAllowed: UInt32 = 0
    var promptDenied: UInt32 = 0
    var updatedAt: Date = Date()

    init(origin: String) { self.origin = origin }

    enum CodingKeys: String, CodingKey {
        case origin, profileID, mediaAllowed, mediaDenied, promptAllowed, promptDenied, updatedAt
    }

    // Records written before the split stored both bit sets in one mask
    // and can't be interpreted safely; they load empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decode(String.self, forKey: .origin)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        mediaAllowed = try c.decodeIfPresent(UInt32.self, forKey: .mediaAllowed) ?? 0
        mediaDenied = try c.decodeIfPresent(UInt32.self, forKey: .mediaDenied) ?? 0
        promptAllowed = try c.decodeIfPresent(UInt32.self, forKey: .promptAllowed) ?? 0
        promptDenied = try c.decodeIfPresent(UInt32.self, forKey: .promptDenied) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    var isEmpty: Bool { mediaAllowed | mediaDenied | promptAllowed | promptDenied == 0 }

    func decision(kind: PermissionKind, requested: UInt32) -> PermissionDecision {
        guard requested != 0 else { return .ask }
        let (allowed, denied) = kind == .media ? (mediaAllowed, mediaDenied) : (promptAllowed, promptDenied)
        if requested & denied != 0 { return .deny }
        if requested & ~allowed == 0 { return .allow }
        return .ask
    }

    /// Bits of a request that may be remembered at all.
    static func rememberable(kind: PermissionKind, requested: UInt32) -> UInt32 {
        kind == .media ? requested & ~MediaPermission.neverRemembered : requested
    }

    mutating func remember(kind: PermissionKind, requested: UInt32, allow: Bool, now: Date = Date()) {
        let bits = Self.rememberable(kind: kind, requested: requested)
        guard bits != 0 else { return }
        switch (kind, allow) {
        case (.media, true): mediaAllowed |= bits; mediaDenied &= ~bits
        case (.media, false): mediaDenied |= bits; mediaAllowed &= ~bits
        case (.prompt, true): promptAllowed |= bits; promptDenied &= ~bits
        case (.prompt, false): promptDenied |= bits; promptAllowed &= ~bits
        }
        updatedAt = now
    }

    /// Feature names for a mask, in a stable order.
    static func featureNames(kind: PermissionKind, mask: UInt32) -> [String] {
        let table: [(UInt32, String)] = kind == .media ? [
            (MediaPermission.microphone, String(localized: "microphone")),
            (MediaPermission.camera, String(localized: "camera")),
            (MediaPermission.systemAudio, String(localized: "system audio")),
            (MediaPermission.screen, String(localized: "screen")),
        ] : [
            (PromptPermission.cameraStream, String(localized: "camera")),
            (PromptPermission.micStream, String(localized: "microphone")),
            (PromptPermission.cameraPanTiltZoom, String(localized: "camera movement")),
            (PromptPermission.geolocation, String(localized: "location")),
            (PromptPermission.notifications, String(localized: "notifications")),
            (PromptPermission.clipboard, String(localized: "clipboard")),
            (PromptPermission.localFonts, String(localized: "local fonts")),
            (PromptPermission.midiSysex, String(localized: "MIDI devices")),
            (PromptPermission.idleDetection, String(localized: "idle detection")),
            (PromptPermission.handTracking, String(localized: "hand tracking")),
            (PromptPermission.windowManagement, String(localized: "window management")),
            (PromptPermission.multipleDownloads, String(localized: "multiple downloads")),
            (PromptPermission.storageAccess, String(localized: "cross-site cookies")),
            (PromptPermission.topLevelStorageAccess, String(localized: "cross-site cookies")),
            (PromptPermission.fileSystemAccess, String(localized: "files and folders")),
            (PromptPermission.keyboardLock, String(localized: "keyboard lock")),
            (PromptPermission.pointerLock, String(localized: "pointer lock")),
            (PromptPermission.protectedMediaIdentifier, String(localized: "protected content")),
            (PromptPermission.registerProtocolHandler, String(localized: "link handling")),
            (PromptPermission.arSession, String(localized: "augmented reality")),
            (PromptPermission.vrSession, String(localized: "virtual reality")),
            (PromptPermission.webAppInstallation, String(localized: "app installation")),
            (PromptPermission.identityProvider, String(localized: "sign-in providers")),
            (PromptPermission.capturedSurfaceControl, String(localized: "shared tab control")),
            (PromptPermission.diskQuota, String(localized: "storage")),
        ]
        var names: [String] = []
        var covered: UInt32 = 0
        for (bit, name) in table where mask & bit != 0 {
            covered |= bit
            if !names.contains(name) { names.append(name) }
        }
        if mask & ~covered != 0 { names.append(String(localized: "other features")) }
        return names
    }
}

extension Array where Element == SitePermission {
    func decision(origin: String, profileID: UUID? = nil, kind: PermissionKind, requested: UInt32) -> PermissionDecision {
        first { $0.origin == origin && $0.profileID == profileID }?.decision(kind: kind, requested: requested) ?? .ask
    }

    mutating func remember(origin: String, profileID: UUID? = nil, kind: PermissionKind, requested: UInt32, allow: Bool, now: Date = Date()) {
        guard SitePermission.rememberable(kind: kind, requested: requested) != 0 else { return }
        if let i = firstIndex(where: { $0.origin == origin && $0.profileID == profileID }) {
            self[i].remember(kind: kind, requested: requested, allow: allow, now: now)
        } else {
            var record = SitePermission(origin: origin)
            record.profileID = profileID
            record.remember(kind: kind, requested: requested, allow: allow, now: now)
            append(record)
        }
    }
}
