import SwiftUI
import AppKit

/// First-run guide: welcome, bring your history over from the
/// browsers found on this Mac, make ToastPeek the default browser, done.
struct OnboardingView: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.colorScheme) private var scheme
    @State private var step: Int
    @State private var forward = true
    @State private var sources: [ImportSource] = []
    @State private var states: [String: ImportState] = [:]
    @State private var isDefault = DefaultBrowser.isDefault
    @State private var fileMessage: String?

    init(startStep: Int = 0) { _step = State(initialValue: startStep) }

    private let steps = 4
    private var tint: Color { store.currentSpace.color }

    enum ImportState: Equatable {
        case running
        case done(history: Int)
        case failed
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                ZStack {
                    switch step {
                    case 0: welcome
                    case 1: importStep
                    case 2: defaultStep
                    default: doneStep
                    }
                }
                .id(step)
                // A short slide with a cross-fade: the outgoing step is gone
                // before it can drift out over the card's edge.
                .transition(.asymmetric(
                    insertion: .offset(x: forward ? 36 : -36).combined(with: .opacity),
                    removal: .offset(x: forward ? -36 : 36).combined(with: .opacity)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                footer
            }
            .frame(width: 640, height: 610)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.28), radius: 40, y: 14)
        }
        .onAppear {
            sources = ImportSources.detect()
            refreshDefault()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if step == 2 { refreshDefault() }
        }
    }

    // MARK: Chrome

    private var backdrop: some View {
        ZStack {
            SpaceBackdrop(color: tint)
            Circle().fill(tint.opacity(0.55)).frame(width: 520).blur(radius: 110).offset(x: -260, y: -200)
            Circle().fill(Color.blue.opacity(0.35)).frame(width: 460).blur(radius: 120).offset(x: 300, y: 240)
        }
        .ignoresSafeArea()
    }

    private var footer: some View {
        HStack {
            if step > 0 && step < steps - 1 {
                Button("Back") { go(step - 1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13, weight: .medium))
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule().fill(i == step ? tint : Color.primary.opacity(0.18))
                        .frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: step)
            Spacer()
            Button(action: next) {
                Text(primaryTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 38)
                    .background(tint.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .frame(height: 72)
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case 0: return "Get Started"
        case steps - 1: return "Start Browsing"
        default: return "Continue"
        }
    }

    private func go(_ to: Int) {
        forward = to > step
        withAnimation(.easeInOut(duration: 0.28)) { step = to }
    }

    private func next() {
        if step == steps - 1 { finish() } else { go(step + 1) }
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.25)) { store.dismissOnboarding() }
    }

    // MARK: Steps

    private func header(_ title: LocalizedStringKey, symbol: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(color: tint.opacity(0.45), radius: 12, y: 5)
            Text(title).font(.system(size: 26, weight: .bold))
        }
        .padding(.top, 38)
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            AppGlyph(size: 120)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            Text("Welcome to ToastPeek").font(.system(size: 32, weight: .bold))
            Spacer()
        }
    }

    private var importStep: some View {
        VStack(spacing: 20) {
            header("Bring your stuff over", symbol: "square.and.arrow.down.fill")
            if sources.isEmpty {
                Text("No other browsers found")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollView {
                    ControlCard {
                        ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { RowDivider(inset: 64) }
                            sourceRow(source)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 312)
            }
            Button { importHistoryFile() } label: {
                Label("Import a history file", systemImage: "doc.badge.plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            if let fileMessage {
                Text(fileMessage).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceRow(_ source: ImportSource) -> some View {
        HStack(spacing: 14) {
            Group {
                if let icon = source.icon { Image(nsImage: icon).resizable().interpolation(.high) }
                else { Image(systemName: "globe").resizable().scaledToFit().padding(6).foregroundStyle(.secondary) }
            }
            .frame(width: 34, height: 34)
            Text(source.name).font(.system(size: 14, weight: .medium))
            Spacer(minLength: 8)
            sourceStatus(source)
        }
        .padding(.horizontal, 16).frame(height: 50)
    }

    @ViewBuilder private func sourceStatus(_ source: ImportSource) -> some View {
        if source.blocked {
            Button("Allow Access…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .help("Safari’s data needs Full Disk Access")
        } else {
            switch states[source.id] {
            case .running:
                ProgressView().controlSize(.small)
            case .done(let h):
                Label(h == 0 ? String(localized: "Nothing new") : String(localized: "\(h) history"),
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(h == 0 ? Color.secondary : Color.green)
            case .failed:
                Button("Try Again") { run(source) }
            case nil:
                Button("Import") { run(source) }
            }
        }
    }

    private var defaultStep: some View {
        VStack(spacing: 22) {
            header("Make it your default", symbol: "safari.fill")
            ControlCard {
                SettingsRow(symbol: "link", tint: .blue, title: "Default browser") {
                    if isDefault {
                        Label("ToastPeek", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
                    } else {
                        Button("Make Default") {
                            DefaultBrowser.request()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { refreshDefault() }
                        }
                    }
                }
                RowDivider(inset: 54)
                SettingsRow(symbol: "magnifyingglass", tint: .indigo, title: "Search engine") {
                    Picker("", selection: $store.searchEngine) {
                        ForEach(SearchEngine.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            .padding(.horizontal, 40)
            .onChange(of: store.searchEngine) { store.scheduleSave() }
            Spacer(minLength: 0)
        }
    }

    private var doneStep: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "checkmark")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .background(tint.gradient, in: Circle())
                .shadow(color: tint.opacity(0.5), radius: 20, y: 8)
            Text("You’re all set").font(.system(size: 30, weight: .bold))
            Spacer()
        }
    }

    // MARK: Actions

    private func refreshDefault() {
        let now = DefaultBrowser.isDefault
        if now != isDefault { withAnimation { isDefault = now } }
    }

    private func run(_ source: ImportSource) {
        states[source.id] = .running
        DispatchQueue.global(qos: .userInitiated).async {
            let payload = ImportSources.read(source)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if payload.history.isEmpty && !source.hasData {
                        states[source.id] = .failed
                        return
                    }
                    let h = store.importHistory(payload.history)
                    withAnimation { states[source.id] = .done(history: h) }
                }
            }
        }
    }

    private func importHistoryFile() {
        if let (added, found) = ImportPanels.importHistory(into: store) {
            fileMessage = found == 0 ? String(localized: "No history found in that file.")
                : String(localized: "History entries imported: \(added)")
        }
    }
}
