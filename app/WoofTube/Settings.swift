import SwiftUI
import SwiftyTube

/// The same presets as Woof Music's SettingsStore.
struct AccentPreset: Identifiable, Hashable {
    let name: String
    let color: Color
    var id: String { name }

    /// The icons in "App Icons" are named after the accent. The main icon is Default Blue.
    var alternateIconName: String? {
        name == AccentPreset.all[0].name ? nil : name
    }

    static let all: [AccentPreset] = [
        AccentPreset(name: "Default Blue", color: Color(red: 0, green: 0.48, blue: 1)),
        AccentPreset(name: "Red", color: Color(red: 0.91, green: 0.22, blue: 0.22)),
        AccentPreset(name: "Orange", color: Color(red: 0.95, green: 0.45, blue: 0.13)),
        AccentPreset(name: "Amber", color: Color(red: 0.98, green: 0.70, blue: 0.15)),
        AccentPreset(name: "Green", color: Color(red: 0.18, green: 0.72, blue: 0.32)),
        AccentPreset(name: "Teal", color: Color(red: 0.12, green: 0.65, blue: 0.60)),
        AccentPreset(name: "Cyan", color: Color(red: 0.15, green: 0.70, blue: 0.90)),
        AccentPreset(name: "Purple", color: Color(red: 0.60, green: 0.35, blue: 0.90)),
        AccentPreset(name: "Pink", color: Color(red: 0.94, green: 0.35, blue: 0.66)),
        AccentPreset(name: "Indigo", color: Color(red: 0.33, green: 0.40, blue: 0.95)),
        AccentPreset(name: "Lime", color: Color(red: 0.55, green: 0.75, blue: 0.20)),
        AccentPreset(name: "Brown", color: Color(red: 0.62, green: 0.43, blue: 0.30))
    ]
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class AppSettings: ObservableObject {
    private static let accentKey = "settings.accentName"
    private static let themeKey = "settings.themeMode"

    @Published var accentName: String {
        didSet { UserDefaults.standard.set(accentName, forKey: Self.accentKey) }
    }
    @Published var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: Self.themeKey) }
    }

    var accentColor: Color {
        AccentPreset.all.first { $0.name == accentName }?.color ?? AccentPreset.all[0].color
    }

    init() {
        let defaults = UserDefaults.standard
        accentName = defaults.string(forKey: Self.accentKey) ?? AccentPreset.all[0].name
        themeMode = ThemeMode(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? .system
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @Environment(Router.self) private var router
    @AppStorage(SearchSettings.tracksHistoryKey) private var tracksSearchHistory = true

    var body: some View {
        List {
            Section {
                NavigationLink {
                    ProfileView()
                } label: {
                    HStack(spacing: Layout.menuRowSpacing) {
                        Avatar(url: session.account?.thumbnailUrl, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.account?.name ?? "YouTube").font(.headline).lineLimit(1)
                            Text("YouTube").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, Layout.cardSpacing)
                }
            }
            Section("Appearance") {
                settingsRow("Appearance", icon: "paintpalette") { AppearanceSettingsView() }
            }
            Section("Playback") {
                settingsRow("Player", icon: "play.circle") { PlayerSettingsView() }
                settingsRow("Downloads", icon: "arrow.down.to.line") { DownloadSettingsView() }
            }
            Section("Search") {
                Toggle(isOn: $tracksSearchHistory) {
                    Label {
                        Text("Search History")
                    } icon: {
                        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90").foregroundStyle(.tint)
                    }
                }
            }
            Section("Support") {
                settingsRow("Diagnostics", icon: "stethoscope") {
                    DiagnosticsView(player: router.player, stream: router.streamSummary)
                }
            }
        }
        .listSectionSpacing(.compact)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func settingsRow<Destination: View>(_ title: String, icon: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(.tint)
            }
        }
    }
}

/// Woof Music's account page, with the accounts saved on this phone.
private struct ProfileView: View {
    @EnvironmentObject private var session: Session
    @Environment(Router.self) private var router
    @State private var confirmsSignOut = false
    @State private var isAddingAccount = false
    @ObservedObject private var downloads = DownloadStore.shared

    private static let notificationSettings = URL(string: "https://www.youtube.com/account_notifications")!
    private static let accountSettings = URL(string: "https://myaccount.google.com")!

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Avatar(url: session.account?.thumbnailUrl, size: 96)
                    Text(session.account?.name ?? "YouTube").font(.title2.bold())
                    if let handle = session.account?.channelHandle {
                        Text(handle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            if let email = session.account?.email {
                Section {
                    LabeledContent("Email", value: email)
                }
            }
            Section {
                ForEach(session.accounts) { saved in
                    Button {
                        guard saved.id != session.currentAccountId else { return }
                        router.close()
                        Task { await session.switchTo(saved) }
                    } label: {
                        HStack(spacing: Layout.rowSpacing) {
                            Avatar(url: saved.thumbnailUrl, size: 32)
                            Text(saved.name).foregroundStyle(.primary).lineLimit(1)
                            Spacer(minLength: 0)
                            if saved.id == session.currentAccountId {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .accessibilityAddTraits(saved.id == session.currentAccountId ? .isSelected : [])
                }
                Button("Add Account", systemImage: "person.badge.plus") { isAddingAccount = true }
            } header: {
                Text("Accounts")
            } footer: {
                Text(downloads.active.isEmpty
                    ? "Each account keeps its own downloads and watch progress on this iPhone."
                    : "You can change account when your downloads finish.")
            }
            .disabled(!downloads.active.isEmpty)
            Section {
                Link(destination: Self.notificationSettings) {
                    Label("Notification Settings", systemImage: "bell.badge")
                }
                Link(destination: Self.accountSettings) {
                    Label("Google Account", systemImage: "person.crop.circle")
                }
            }
            Section {
                Button("Sign Out", role: .destructive) { confirmsSignOut = true }
                    .disabled(!downloads.active.isEmpty)
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingAccount) {
            AddAccountSheet()
        }
        .confirmationDialog("Sign out of this account?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                router.close()
                Task { await session.signOut() }
            }
        }
    }
}

private struct PlayerSettingsView: View {
    @Environment(Router.self) private var router
    @AppStorage(DislikeCounts.enabledKey) private var showsDislikeCounts = true

    var body: some View {
        List {
            Section {
                Picker(selection: Bindable(router).maxHeight) {
                    ForEach(Router.qualities, id: \.self) { Text("\($0)p").tag($0) }
                } label: {
                    Label {
                        Text("Maximum Quality")
                    } icon: {
                        Image(systemName: "sparkles.tv").glyphMotion(.qualitySparkle, trigger: router.maxHeight)
                    }
                }
                Toggle(isOn: Bindable(router).autoplay) {
                    Label {
                        Text("Autoplay")
                    } icon: {
                        Image(systemName: "play.square.stack").glyphMotion(router.autoplay ? .nextCard : .pop, trigger: router.autoplay)
                    }
                }
                Toggle("Picture in Picture", systemImage: "pip", isOn: Bindable(router).allowsPictureInPicture)
            } footer: {
                Text("Autoplay starts the first Up Next video when one ends. Picture in Picture keeps the video in a small window when you leave the app.")
            }
            Section {
                Toggle(isOn: Bindable(router).skipsSponsors) {
                    Label {
                        Text("Skip Sponsors")
                    } icon: {
                        Image(systemName: "forward.end").glyphMotion(router.skipsSponsors ? .dashAhead : .pop, trigger: router.skipsSponsors)
                    }
                }
            } footer: {
                Text("Uses SponsorBlock's community list. It receives part of a code shared by many videos, not which one you watch.")
            }
            Section {
                Toggle(isOn: $showsDislikeCounts) {
                    Label {
                        Text("Dislike Counts")
                    } icon: {
                        Image(systemName: "hand.thumbsdown").glyphMotion(showsDislikeCounts ? .dislike : .rise, trigger: showsDislikeCounts)
                    }
                }
            } footer: {
                Text("YouTube hides these numbers. They are estimates from Return YouTube Dislike, which receives the ID of each video you open or see in a feed.")
            }
        }
        .navigationTitle("Player")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 6)

    var body: some View {
        List {
            Section {
                Picker(selection: $settings.themeMode) {
                    ForEach(ThemeMode.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    Label {
                        Text("Theme Mode")
                    } icon: {
                        MorphingGlyph(systemName: settings.themeMode.symbol)
                            .glyphMotion(settings.themeMode == .dark ? .moonRise : .sunRise, trigger: settings.themeMode)
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Choose how the app follows your device appearance.")
            }

            Section {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AccentPreset.all) { preset in
                        Button {
                            settings.accentName = preset.name
                            applyAppIcon(of: preset)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(preset.color)
                                    .frame(width: 34, height: 34)
                                if settings.accentName == preset.name {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Applies to buttons, highlights, selected items, and the app icon.")
            }
        }
        .id(settings.accentName)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// iOS shows its own message when the icon changes.
    private func applyAppIcon(of preset: AccentPreset) {
        let application = UIApplication.shared
        guard application.supportsAlternateIcons, application.alternateIconName != preset.alternateIconName else { return }
        application.setAlternateIconName(preset.alternateIconName)
    }
}

/// Shows what the app is doing, because a phone has no console to read.
private struct DiagnosticsView: View {
    @ObservedObject var player: MpvPlayer
    let stream: String?
    @State private var state = ""

    private var report: String {
        let download = DownloadStore.shared.lastReport.map { [$0] } ?? []
        let crashes = "Crash and hang reports: \(CrashReports.saved.count)"
        return ([stream ?? "No stream", state, crashes] + download + player.recentLog).joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            ForEach(CrashReports.saved, id: \.self) { file in
                ShareLink(item: file) {
                    Label(file.deletingPathExtension().lastPathComponent, systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .padding(.horizontal, Layout.screenPadding)
            }
            Text(report)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.screenPadding)
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ShareLink(item: report)
        }
        .task { state = await player.diagnostics() }
    }
}
