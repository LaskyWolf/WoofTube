import SwiftUI
import SwiftyTube
import WebKit

/// A Google sign-in kept on this phone, to switch back to.
struct SavedAccount: Codable, Identifiable {
    let id: String
    let name: String
    let thumbnailUrl: String?
    let auth: AuthState
}

/// Keeps the signed-in cookies in the Keychain and hands them to the YouTube client.
@MainActor
final class Session: ObservableObject {
    @Published private(set) var isSignedIn = false
    /// True until the saved sign-in has been looked for, so a signed-in person never sees the sign-in page.
    @Published private(set) var isRestoring = true
    @Published var isExpired = false
    @Published private(set) var account: AccountInfo?
    @Published var unseenNotifications = 0
    @Published private(set) var accounts: [SavedAccount] = []
    /// Changes when another account takes over.
    @Published private(set) var generation = 0
    private var currentAuth = AuthState.guest

    private let store = SecureStore(service: "com.laskywolf.wooftube.session")
    private let key = "auth"
    private let accountsKey = "accounts"
    private static let accountRetryDelay = Duration.seconds(2)

    /// Google can answer as a guest while the session is stale, and that isn't an account.
    var currentAccountId: String? {
        guard let account, !account.name.isEmpty, account.name != "Guest" else { return nil }
        return account.email ?? account.name
    }

    func restore() async {
        defer { DownloadStore.shared.sessionReady() }
        if let data = try? store.load(for: accountsKey) {
            accounts = (try? JSONDecoder().decode([SavedAccount].self, from: data)) ?? []
        }
        guard let data = try? store.load(for: key),
              let auth = try? JSONDecoder().decode(AuthState.self, from: data) else {
            isRestoring = false
            return
        }
        currentAuth = auth
        await InnerTubeClient.wooftube.updateAuth(auth)
        isSignedIn = true
        isRestoring = false
        await refreshIfStale(auth)
        await loadAccount()
        openStorageOfCurrentAccount()
    }

    func signIn(_ auth: AuthState) async {
        account = nil
        save(auth)
        await InnerTubeClient.wooftube.updateAuth(auth)
        isSignedIn = true
        await loadAccount()
        if currentAccountId == nil {
            try? await Task.sleep(for: Self.accountRetryDelay)
            await loadAccount()
        }
        openStorageOfCurrentAccount()
        accountChanged()
        await clearWebCookies()
    }

    func switchTo(_ saved: SavedAccount) async {
        account = nil
        unseenNotifications = 0
        save(saved.auth)
        // Before the storage, so a queued download never starts with the previous account's sign-in.
        await InnerTubeClient.wooftube.updateAuth(saved.auth)
        openStorage(of: saved.id)
        await refreshIfStale(saved.auth)
        await loadAccount()
        accountChanged()
    }

    private func accountChanged() {
        generation += 1
        Task { await StreamLoader.forgetAll() }
        Subscriptions.shared.reset()
        Task { await Subscriptions.shared.load() }
    }

    /// The app keeps its own copy of the sign-in, so Google's stays nowhere else on the phone.
    private func clearWebCookies() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeCookies],
            modifiedSince: .distantPast
        )
    }

    /// Google remembers the last sign-in, and this makes it ask for an account again.
    func clearWebSignIn() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }

    func refreshUnseenNotifications() async {
        guard let json = try? await YouTubeAPI.post("notification/get_unseen_count", body: [:]) else { return }
        let count = JSON.first("unseenCount", in: json)
        unseenNotifications = count as? Int ?? Int(count as? String ?? "") ?? 0
    }

    // ponytail: if Google still doesn't answer who signed in, the data stays put until the next launch asks again.
    private func openStorageOfCurrentAccount() {
        if let id = currentAccountId { openStorage(of: id) }
    }

    /// Moves the app to the account's downloads and watch positions.
    private func openStorage(of accountId: String) {
        let storage = ProfileStorage.claim(for: accountId)
        guard storage != ProfileStorage.active else { return }
        ProfileStorage.activate(storage)
        WatchPositions.reload()
        SeenVideos.reload()
        DownloadStore.shared.reloadForActiveProfile()
    }

    private func loadAccount() async {
        account = try? await InnerTubeClient.wooftube.accountInfo()
        rememberCurrentAccount()
    }

    private func rememberCurrentAccount() {
        guard let account, let id = currentAccountId else { return }
        let saved = SavedAccount(id: id, name: account.name, thumbnailUrl: account.thumbnailUrl, auth: currentAuth)
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index] = saved
        } else {
            accounts.append(saved)
        }
        saveAccounts()
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            try? store.save(data, for: accountsKey)
        }
    }

    /// Removes this account from the phone, and moves to another saved one if there is one.
    /// Also clears the web view's cookies, so the next sign-in can pick another account.
    func signOut() async {
        SavedHome.clear()
        accounts.removeAll { $0.id == currentAccountId || $0.auth == currentAuth }
        saveAccounts()
        await clearWebSignIn()
        isExpired = false
        if let next = accounts.first {
            await switchTo(next)
            return
        }
        try? store.delete(for: key)
        await InnerTubeClient.wooftube.updateAuth(.guest)
        currentAuth = .guest
        isSignedIn = false
        account = nil
        unseenNotifications = 0
        Subscriptions.shared.reset()
    }

    /// Google rotates its tokens, and a stale session answers as a guest instead of failing.
    /// A network error says nothing about the session, so it changes nothing here.
    private func refreshIfStale(_ auth: AuthState) async {
        let tube = InnerTubeClient.wooftube
        guard let isValid = try? await tube.verifySession(), !isValid else { return }
        let reissued = await SessionTokenRefresher.shared.refreshRotatedTokens(baseCookies: auth.cookies)
        guard !reissued.isEmpty else {
            isExpired = true
            return
        }
        var refreshed = auth
        refreshed.cookies = reissued
        await tube.updateAuth(refreshed)
        if (try? await tube.verifySession()) == true {
            save(refreshed)
        } else {
            isExpired = true
        }
    }

    private func save(_ auth: AuthState) {
        currentAuth = auth
        rememberCurrentAccount()
        if let data = try? JSONEncoder().encode(auth) {
            try? store.save(data, for: key)
        }
    }
}
