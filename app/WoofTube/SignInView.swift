import SwiftUI
import SwiftyTube
import WebKit

struct SignInView: View {
    @EnvironmentObject private var session: Session
    @State private var failed = false

    var body: some View {
        NavigationStack {
            GoogleSignInWebView { auth in
                if let auth {
                    Task { await session.signIn(auth) }
                } else {
                    failed = true
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Sign-in didn't finish", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Close the app and sign in again.")
            }
        }
    }
}

/// Google's sign-in page. SwiftyTube's docs require the desktop user agent and
/// polling the cookies, because the first cookies after the redirect are incomplete.
private struct GoogleSignInWebView: UIViewRepresentable {
    let onFinish: (AuthState?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.customUserAgent = LoginWebviewHarvest.userAgent
        webView.navigationDelegate = context.coordinator
        let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onFinish: (AuthState?) -> Void
        private var isCollecting = false

        init(onFinish: @escaping (AuthState?) -> Void) {
            self.onFinish = onFinish
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.host() == "www.youtube.com", !isCollecting else { return }
            isCollecting = true
            Task { @MainActor in
                guard let session = await LoginWebviewHarvest.collectSession(from: webView) else {
                    onFinish(nil)
                    return
                }
                onFinish(AuthState(
                    cookies: session.cookies,
                    sapisid: session.sapisid,
                    visitorData: await pageConfig("VISITOR_DATA", in: webView),
                    dataSyncId: await pageConfig("DATASYNC_ID", in: webView)
                ))
            }
        }

        @MainActor
        private func pageConfig(_ name: String, in webView: WKWebView) async -> String? {
            let value = (try? await webView.evaluateJavaScript("window.yt?.config_?.\(name) ?? ''")) as? String
            return value?.isEmpty == false ? value : nil
        }
    }
}
