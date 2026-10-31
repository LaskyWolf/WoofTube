import SwiftUI
import SwiftyTube

/// The same presets as Woof Music's SettingsStore.
struct AccentPreset: Identifiable, Hashable {
    let name: String
    let color: Color
    var id: String { name }

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
    @EnvironmentObject private var router: Router

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
    @EnvironmentObject private var router: Router
    @State private var confirmsSignOut = false
    @State private var isAddingAccount = false

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
            Section("Accounts") {
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
            }
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
    @EnvironmentObject private var router: Router
    @AppStorage(DislikeCounts.enabledKey) private var showsDislikeCounts = true

    var body: some View {
        List {
            Section {
                Picker(selection: $router.maxHeight) {
                    ForEach(Router.qualities, id: \.self) { Text("\($0)p").tag($0) }
                } label: {
                    Label("Maximum Quality", systemImage: "sparkles.tv")
                }
                Toggle(isOn: $router.autoplay) {
                    Label("Autoplay", systemImage: "play.square.stack")
                }
            } footer: {
                Text("Autoplay starts the first Up Next video when one ends.")
            }
            Section {
                Toggle(isOn: $router.skipsSponsors) {
                    Label("Skip Sponsors", systemImage: "forward.end")
                }
            } footer: {
                Text("Uses SponsorBlock's community list, which receives the ID of each video you watch.")
            }
            Section {
                Toggle(isOn: $showsDislikeCounts) {
                    Label("Dislike Counts", systemImage: "hand.thumbsdown")
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
                    Label("Theme Mode", systemImage: "sun.max")
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
                Text("Applies to buttons, highlights, and selected items.")
            }
        }
        .id(settings.accentName)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shows what the app is doing, because a phone has no console to read.
private struct DiagnosticsView: View {
    @ObservedObject var player: MpvPlayer
    let stream: String?
    @State private var state = ""

    private var report: String {
        let feedTypes = "Feed content types: " + FeedParser.seenContentTypes.sorted().joined(separator: ", ")
        return ([stream ?? "No stream", state, feedTypes] + player.recentLog).joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
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
