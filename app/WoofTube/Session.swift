import SwiftUI
import SwiftyTube
import WebKit

/// Keeps the signed-in cookies in the Keychain and hands them to the YouTube client.
@MainActor
final class Session: ObservableObject {
    @Published private(set) var isSignedIn = false
    @Published var isExpired = false
    @Published private(set) var account: AccountInfo?
    @Published var unseenNotifications = 0

    private let store = SecureStore(service: "com.laskywolf.wooftube.session")
    private let key = "auth"

    func restore() async {
        guard let data = try? store.load(for: key),
              let auth = try? JSONDecoder().decode(AuthState.self, from: data) else { return }
        await InnerTubeClient.wooftube.updateAuth(auth)
        isSignedIn = true
        await refreshIfStale(auth)
        await loadAccount()
    }

    func signIn(_ auth: AuthState) async {
        save(auth)
        await InnerTubeClient.wooftube.updateAuth(auth)
        isSignedIn = true
        await loadAccount()
    }

    func refreshUnseenNotifications() async {
        guard let json = try? await YouTubeAPI.post("notification/get_unseen_count", body: [:]) else { return }
        let count = JSON.first("unseenCount", in: json)
        unseenNotifications = count as? Int ?? Int(count as? String ?? "") ?? 0
    }

    private func loadAccount() async {
        account = try? await InnerTubeClient.wooftube.accountInfo()
    }

    /// Also clears the web view's cookies, so the next sign-in can pick another account.
    func signOut() async {
        try? store.delete(for: key)
        await InnerTubeClient.wooftube.updateAuth(.guest)
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        isExpired = false
        isSignedIn = false
        account = nil
        unseenNotifications = 0
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
        if let data = try? JSONEncoder().encode(auth) {
            try? store.save(data, for: key)
        }
    }
}
