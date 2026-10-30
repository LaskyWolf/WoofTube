import SwiftUI
import SwiftyTube
import WebKit

/// Keeps the signed-in cookies in the Keychain and hands them to the YouTube client.
@MainActor
final class Session: ObservableObject {
    @Published private(set) var isSignedIn = false

    private let store = SecureStore(service: "com.laskywolf.wooftube.session")
    private let key = "auth"

    func restore() async {
        guard let data = try? store.load(for: key),
              let auth = try? JSONDecoder().decode(AuthState.self, from: data) else { return }
        await InnerTubeClient.wooftube.updateAuth(auth)
        isSignedIn = true
    }

    func signIn(_ auth: AuthState) async {
        if let data = try? JSONEncoder().encode(auth) {
            try? store.save(data, for: key)
        }
        await InnerTubeClient.wooftube.updateAuth(auth)
        isSignedIn = true
    }

    /// Also clears the web view's cookies, so the next sign-in can pick another account.
    func signOut() async {
        try? store.delete(for: key)
        await InnerTubeClient.wooftube.updateAuth(.guest)
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        isSignedIn = false
    }
}
