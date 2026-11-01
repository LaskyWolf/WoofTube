import SwiftUI
import SwiftyTube

/// Appends problems to a file, so what only happens on the phone can be read and shared later.
/// It rotates past about 1 MB and keeps nothing while Incognito is on.
final class FileLog {
    static let shared = FileLog()

    private let queue = DispatchQueue(label: "com.laskywolf.wooftube.log")
    private let maxBytes = 1_000_000
    /// Only touched on `queue`.
    private var handle: FileHandle?
    private var size = 0

    var fileURL: URL { URL.documentsDirectory.appending(path: "log.txt") }

    func append(_ category: String, _ level: String, _ message: String) {
        guard !SearchSettings.isIncognito else { return }
        let line = "\(Date().formatted(.iso8601)) [\(level)][\(category)] \(Self.safe(message))\n"
        queue.async { [self] in
            let data = Data(line.utf8)
            if handle == nil {
                handle = try? FileHandle(forWritingTo: fileURL)
                size = Int((try? handle?.seekToEnd()) ?? 0)
            }
            if let handle, size <= maxBytes, (try? handle.write(contentsOf: data)) != nil {
                size += data.count
                return
            }
            // No file yet, or past the limit: start a fresh one.
            try? handle?.close()
            handle = nil
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Addresses can carry the phone's IP and video IDs, and this log can be shared.
    static func safe(_ line: String) -> String {
        line.replacingOccurrences(of: #"(https?://[^/\s]+)\S*"#, with: "$1/…", options: .regularExpression)
    }

    static func selfCheck() {
        assert(safe("got https://a.example/b?ip=1 back") == "got https://a.example/… back")
        assert(safe("no address") == "no address")
    }
}

/// Hidden page, opened by long-pressing the account in Settings: build, signing, account,
/// playback and recent log errors, with a button that copies everything for a bug report.
struct DiagnosticsView: View {
    @EnvironmentObject private var session: Session
    @Environment(Router.self) private var router
    @State private var sections: [DiagnosticsSection] = []
    @State private var accountCheck: String?
    @State private var isCheckingAccount = false
    @State private var copied = false
    @State private var problems: [String] = []

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.label) { row in
                        LabeledContent(row.label) {
                            Text(row.value)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section("Actions") {
                Button {
                    Task { await checkAccount() }
                } label: {
                    LabeledContent {
                        if isCheckingAccount { ProgressView() } else if let accountCheck { Text(accountCheck) }
                    } label: {
                        Label("Check Account", systemImage: "person.badge.shield.checkmark")
                    }
                }
                .disabled(isCheckingAccount)
                if FileManager.default.fileExists(atPath: FileLog.shared.fileURL.path()) {
                    ShareLink(item: FileLog.shared.fileURL) {
                        Label("Share Log File", systemImage: "doc.text")
                    }
                }
                ForEach(CrashReports.saved, id: \.self) { file in
                    ShareLink(item: file) {
                        Label(file.deletingPathExtension().lastPathComponent, systemImage: "exclamationmark.triangle")
                    }
                }
                Button(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = report
                    copied = true
                }
            }

            Section {
                if problems.isEmpty {
                    Text("No warnings or errors in the log.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(problems.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Clear Problems", systemImage: "trash", role: .destructive) {
                        DiagnosticsSection.clearProblems()
                        problems = []
                    }
                }
            } header: {
                Text("Recent Problems")
            } footer: {
                Text("The last warnings and errors from the log file, newest last. Clearing hides them here; the log file keeps them.")
            }

            Section("Player Log") {
                if router.player.recentLog.isEmpty {
                    Text("Nothing since the app opened.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(router.player.recentLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            sections = await DiagnosticsSection.all(session: session, router: router)
            problems = DiagnosticsSection.recentProblems()
        }
    }

    private var report: String {
        var lines = sections.flatMap { section in
            ["## \(section.title)"] + section.rows.map { "\($0.label): \($0.value)" }
        }
        if let accountCheck { lines.append("Account check: \(accountCheck)") }
        lines.append("## Recent Problems")
        lines += problems
        lines.append("## Player Log")
        lines += router.player.recentLog
        return lines.joined(separator: "\n")
    }

    private func checkAccount() async {
        isCheckingAccount = true
        defer { isCheckingAccount = false }
        do {
            let info = try await InnerTubeClient.wooftube.accountInfo()
            accountCheck = info.name.isEmpty || info.name == "Guest" ? "Guest menu (session not recognised)" : "OK, \(info.name)"
        } catch {
            accountCheck = "Failed: \(error.localizedDescription)"
        }
    }
}

struct DiagnosticsSection: Identifiable {
    struct Row {
        let label: String
        let value: String
    }

    let title: String
    let rows: [Row]
    var id: String { title }

    @MainActor
    static func all(session: Session, router: Router) async -> [DiagnosticsSection] {
        [app(), signing(), await account(session), await playback(router)]
    }

    // MARK: - Sections

    private static func app() -> DiagnosticsSection {
        let info = Bundle.main.infoDictionary
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return DiagnosticsSection(title: "App", rows: [
            Row(label: "Version", value: info?["CFBundleShortVersionString"] as? String ?? "?"),
            Row(label: "Build", value: info?["CFBundleVersion"] as? String ?? "?"),
            Row(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "?"),
            Row(label: "iOS", value: UIDevice.current.systemVersion),
            Row(label: "Device", value: model),
            Row(label: "Language", value: Locale.current.identifier)
        ])
    }

    /// What the signing tool's provisioning profile allows, read from the app.
    private static func signing() -> DiagnosticsSection {
        guard let data = try? Data(contentsOf: Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let profile = (try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil)) as? [String: Any] else {
            return DiagnosticsSection(title: "Signing", rows: [Row(label: "Profile", value: "None (ad-hoc or unsigned)")])
        }
        let entitlements = profile["Entitlements"] as? [String: Any] ?? [:]
        func list(_ key: String) -> String {
            let values = entitlements[key] as? [String] ?? []
            return values.isEmpty ? "None" : values.joined(separator: ", ")
        }
        let devices = profile["ProvisionsAllDevices"] as? Bool == true
            ? "All devices"
            : "\((profile["ProvisionedDevices"] as? [String])?.count ?? 0) devices"
        return DiagnosticsSection(title: "Signing", rows: [
            Row(label: "Profile", value: profile["Name"] as? String ?? "?"),
            Row(label: "Team", value: "\(profile["TeamName"] as? String ?? "?") (\((profile["TeamIdentifier"] as? [String])?.first ?? "?"))"),
            Row(label: "Expires", value: (profile["ExpirationDate"] as? Date)?.formatted(date: .abbreviated, time: .omitted) ?? "?"),
            Row(label: "Devices", value: devices),
            Row(label: "App Groups", value: list("com.apple.security.application-groups")),
            Row(label: "Keychain Groups", value: list("keychain-access-groups"))
        ])
    }

    @MainActor
    private static func account(_ session: Session) async -> DiagnosticsSection {
        let auth = await InnerTubeClient.wooftube.currentAuth()
        return DiagnosticsSection(title: "Account", rows: [
            Row(label: "Signed In", value: session.isSignedIn ? "Yes" : "No"),
            Row(label: "Name", value: session.isSignedIn ? session.account?.name ?? "Unknown" : "–"),
            Row(label: "Channel", value: YouTubeAPI.secondaryChannel(in: auth.dataSyncId) == nil ? "Main" : "Secondary"),
            Row(label: "Visitor Data", value: auth.visitorData == nil ? "Missing" : "Present"),
            Row(label: "Saved Accounts", value: "\(session.accounts.count)"),
            Row(label: "Incognito", value: SearchSettings.isIncognito ? "On" : "Off"),
            Row(label: "Search History", value: SearchSettings.tracksHistory ? "Tracked" : "Off")
        ])
    }

    @MainActor
    private static func playback(_ router: Router) async -> DiagnosticsSection {
        func onOff(_ isOn: Bool) -> String { isOn ? "On" : "Off" }
        let dislikes = UserDefaults.standard.object(forKey: DislikeCounts.enabledKey) as? Bool ?? true
        let state = await router.player.diagnostics().split(separator: "\n").compactMap { line -> Row? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 ? Row(label: parts[0], value: parts[1]) : nil
        }
        return DiagnosticsSection(title: "Playback", rows: [
            Row(label: "Stream", value: router.streamSummary ?? "None"),
            Row(label: "Maximum Quality", value: "\(router.maxHeight)p"),
            Row(label: "Autoplay", value: onOff(router.autoplay)),
            Row(label: "Picture in Picture", value: onOff(router.allowsPictureInPicture)),
            Row(label: "Skip Sponsors", value: onOff(router.skipsSponsors)),
            Row(label: "Dislike Counts", value: onOff(dislikes)),
            Row(label: "Last Download", value: DownloadStore.shared.lastReport ?? "None"),
            Row(label: "Crash and Hang Reports", value: "\(CrashReports.saved.count)")
        ] + state)
    }

    // MARK: - Problems

    /// Logged by "Clear Problems": the list starts after the last one, so the
    /// log file itself stays whole for "Share Log File".
    private static let clearedMarker = "Recent Problems cleared"
    private static let problemsShown = 30

    static func clearProblems() {
        FileLog.shared.append("diagnostics", "NOTICE", clearedMarker)
    }

    static func recentProblems() -> [String] {
        (try? String(contentsOf: FileLog.shared.fileURL, encoding: .utf8)).map(problems) ?? []
    }

    /// The last warning and error lines of the log, after the last clear.
    private static func problems(in text: String) -> [String] {
        let lines = text.split(separator: "\n")
        let start = lines.lastIndex { $0.hasSuffix(clearedMarker) }.map { $0 + 1 } ?? lines.startIndex
        let found = lines[start...].filter { $0.contains("[ERROR]") || $0.contains("[WARNING]") }
        return found.suffix(problemsShown).map(String.init)
    }

    static func selfCheck() {
        let log = "t [ERROR][a] old\nt [NOTICE][d] \(clearedMarker)\nt [NOTICE][a] fine\nt [WARNING][a] new\nt [ERROR][a] newer"
        assert(problems(in: log) == ["t [WARNING][a] new", "t [ERROR][a] newer"])
        assert(problems(in: "").isEmpty)
        FileLog.selfCheck()
    }
}
