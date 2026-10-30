import SwiftUI
import SwiftyTube

extension InnerTubeClient {
    static let wooftube = InnerTubeClient(config: .youtube)
}

@main
struct WoofTubeApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isSignedIn {
                    HomeView()
                } else {
                    SignInView()
                }
            }
            .environmentObject(session)
            .task { await session.restore() }
        }
    }
}
