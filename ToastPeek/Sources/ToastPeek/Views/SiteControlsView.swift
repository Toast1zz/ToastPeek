import SwiftUI
import WebKit

/// Site controls, behind the button beside Copy Link in the address
/// pill: this site's extensions (Content Blocker, Dark Mode), its Boost,
/// zoom, camera and microphone, and its stored data.
extension BrowserStore {
    private static func siteMatches(_ list: [String], _ host: String) -> Bool {
        let h = host.lowercased()
        return list.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Registrable-ish host used for per-site lists (drops a leading "www.").
    static func siteKey(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    func isBlockingActive(on host: String) -> Bool {
        isContentBlockingEnabled && !Self.siteMatches(blockerExemptHosts, host)
    }

    func setBlocking(_ on: Bool, for host: String) {
        let key = Self.siteKey(host)
        if on {
            blockerExemptHosts.removeAll { Self.siteMatches([$0], key) || $0 == key }
            if let ext = extensions.first(where: { $0.path == Self.contentBlockerBuiltinPath }), !ext.isEnabled {
                setExtensionEnabled(ext, true)
            }
        } else if !blockerExemptHosts.contains(key) {
            blockerExemptHosts.append(key)
        }
        ContentBlocker.setExemptHosts(blockerExemptHosts)
        applyNativeExtensionsToOpenTabs()
    }

    func isDarkModeActive(on host: String) -> Bool {
        guard isDarkModeEnabled else { return false }
        if darkModeHosts.isEmpty { return !Self.siteMatches(darkModeExcludedHosts, host) }
        return Self.siteMatches(darkModeHosts, host)
    }

    func setDarkMode(_ on: Bool, for host: String) {
        let key = Self.siteKey(host)
        let ext = extensions.first(where: { $0.path == Self.darkModeBuiltinPath })
        if on {
            darkModeExcludedHosts.removeAll { $0 == key }
            if !isDarkModeEnabled {
                // Turning it on from one site starts a site list, not "every site".
                darkModeHosts = [key]
                if let ext { setExtensionEnabled(ext, true) }
            } else if !darkModeHosts.isEmpty, !darkModeHosts.contains(key) {
                darkModeHosts.append(key)
            }
        } else if darkModeHosts.isEmpty {
            if !darkModeExcludedHosts.contains(key) { darkModeExcludedHosts.append(key) }
        } else {
            darkModeHosts.removeAll { Self.siteMatches([$0], key) || $0 == key }
            // An empty list means every site; the last site off turns Dark Mode off.
            if darkModeHosts.isEmpty, let ext { setExtensionEnabled(ext, false) }
        }
        scheduleSave()
        applyNativeExtensionsToOpenTabs()
    }

    func boostIndex(for host: String) -> Int? {
        boosts.firstIndex { Boost.patternMatches($0.hostPattern, host: host) }
    }

    func createBoost(for host: String) {
        let key = Self.siteKey(host)
        boosts.append(Boost(name: key, hostPattern: key))
        scheduleSave()
        onOpenSettings?(.boosts)
    }

    func mediaDecision(origin: String, profileID: UUID, bit: UInt32) -> PermissionDecision {
        sitePermissions.decision(origin: origin, profileID: profileID, kind: .media, requested: bit)
    }

    func setMediaDecision(_ decision: PermissionDecision, origin: String, profileID: UUID, bit: UInt32) {
        var record = sitePermissions.first { $0.origin == origin && $0.profileID == profileID } ?? SitePermission(origin: origin)
        record.profileID = profileID
        record.mediaAllowed &= ~bit
        record.mediaDenied &= ~bit
        if decision == .allow { record.mediaAllowed |= bit }
        if decision == .deny { record.mediaDenied |= bit }
        record.updatedAt = Date()
        sitePermissions.removeAll { $0.origin == origin && $0.profileID == profileID }
        if decision != .allow { for controller in controllers.values where controller.dataStoreID == profileID { controller.stopCapture() } }
        if !record.isEmpty { sitePermissions.append(record) }
        scheduleSave()
    }

    /// Removes this site's cookies and storage from the tab's Space only.
    func clearSiteData(for tab: BrowserTab, completion: @escaping () -> Void) {
        let key = Self.siteKey(tab.host)
        let store = WKWebsiteDataStore(forIdentifier: profileSpace(for: tab).dataStoreID)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let mine = records.filter { r in
                let name = r.displayName.lowercased()
                return name == key || name.hasSuffix("." + key) || key.hasSuffix("." + name)
            }
            store.removeData(ofTypes: types, for: mine) {
                MainActor.assumeIsolated { completion() }
            }
        }
    }
}

struct SiteControlsView: View {
    let tab: BrowserTab
    @EnvironmentObject var store: BrowserStore
    @State private var cleared = false

    private var host: String { tab.host }
    private var origin: String { SiteOrigin.make(tab.url) }
    private var profileID: UUID { store.profileSpace(for: tab).dataStoreID }
    private var secure: Bool { store.controller(forTabID: tab.id)?.isSecureConnection == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                FaviconView(host: host, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(BrowserStore.siteKey(host)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(secure ? "Connection is secure" : "Connection is not secure")
                        .font(.system(size: 11))
                        .foregroundStyle(secure ? Color.secondary : Color.orange)
                }
                Spacer(minLength: 0)
            }

            ControlCard {
                ControlToggleRow(symbol: "hand.raised.fill", tint: .blue, title: "Content Blocker",
                                 isOn: Binding(get: { store.isBlockingActive(on: host) },
                                               set: { store.setBlocking($0, for: host); reloadSoon() }))
                CardDivider()
                ControlToggleRow(symbol: "moon.fill", tint: .indigo, title: "Dark Mode",
                                 isOn: Binding(get: { store.isDarkModeActive(on: host) },
                                               set: { store.setDarkMode($0, for: host); reloadSoon() }))
            }

            ControlCard {
                if let i = store.boostIndex(for: host) {
                    ControlToggleRow(symbol: "paintbrush.pointed.fill", tint: .pink, title: "Boost",
                                     isOn: Binding(get: { store.boosts[i].isEnabled },
                                                   set: { store.boosts[i].isEnabled = $0; store.scheduleSave(); store.scheduleBoostApply() }))
                    CardDivider()
                    ControlButtonRow(symbol: "slider.horizontal.3", tint: .gray, title: "Edit Boost…") {
                        store.onOpenSettings?(.boosts)
                    }
                } else {
                    ControlButtonRow(symbol: "paintbrush.pointed.fill", tint: .pink, title: "New Boost for This Site") {
                        store.createBoost(for: host)
                    }
                }
            }

            ControlCard {
                ZoomRow(controller: store.controller(forTabID: tab.id))
                CardDivider()
                PermissionRow(symbol: "video.fill", tint: .green, title: "Camera",
                              decision: Binding(get: { store.mediaDecision(origin: origin, profileID: profileID, bit: MediaPermission.camera) },
                                                set: { store.setMediaDecision($0, origin: origin, profileID: profileID, bit: MediaPermission.camera) }))
                CardDivider()
                PermissionRow(symbol: "mic.fill", tint: .orange, title: "Microphone",
                              decision: Binding(get: { store.mediaDecision(origin: origin, profileID: profileID, bit: MediaPermission.microphone) },
                                                set: { store.setMediaDecision($0, origin: origin, profileID: profileID, bit: MediaPermission.microphone) }))
            }

            ControlCard {
                ControlButtonRow(symbol: "trash.fill", tint: .red,
                                 title: cleared ? "Site Data Cleared" : "Clear Cookies and Site Data") {
                    store.clearSiteData(for: tab) {
                        cleared = true
                        store.controller(forTabID: tab.id)?.reload()
                    }
                }
                .disabled(cleared)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    /// Native extensions apply on the next load.
    private func reloadSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.controller(forTabID: tab.id)?.reload()
        }
    }
}

// MARK: - Card pieces (shared with Settings)

/// Rounded group with a hairline border, as in settings and popovers.
struct ControlCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.leading, 12)
    }
}

/// Small colored square holding a white symbol (settings rows).
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

struct ControlToggleRow: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 12).frame(height: 40)
    }
}

struct ControlButtonRow: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: tint)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(hovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ZoomRow: View {
    let controller: WebTabController?
    var body: some View {
        if let controller { Live(controller: controller) } else { EmptyView() }
    }
    private struct Live: View {
        @ObservedObject var controller: WebTabController
        @State private var percent = 100
        var body: some View {
            HStack(spacing: 10) {
                IconTile(symbol: "plus.magnifyingglass", tint: .teal)
                Text("Zoom").font(.system(size: 13))
                Spacer(minLength: 8)
                ChromeButton(symbol: "minus", label: "Zoom Out", size: 24) { controller.zoomOut(); refresh() }
                Button("\(percent)%") { controller.zoomReset(); refresh() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(minWidth: 40)
                    .help("Actual Size")
                ChromeButton(symbol: "plus", label: "Zoom In", size: 24) { controller.zoomIn(); refresh() }
            }
            .padding(.horizontal, 12).frame(height: 40)
            .onAppear(perform: refresh)
        }
        private func refresh() { percent = Int(controller.zoomPercent.rounded()) }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    @Binding var decision: PermissionDecision
    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Picker("", selection: $decision) {
                Text("Ask").tag(PermissionDecision.ask)
                Text("Allow").tag(PermissionDecision.allow)
                Text("Block").tag(PermissionDecision.deny)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(title)
        }
        .padding(.horizontal, 12).frame(height: 40)
    }
}
