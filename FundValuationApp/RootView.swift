import SwiftUI

struct RootView: View {
    @StateObject private var session = SessionViewModel()

    var body: some View {
        ZStack {
            Color(hex: 0x1C1C1E).ignoresSafeArea()
            if session.isAuthenticated {
                MainView(session: session)
            } else {
                AuthFlowView(session: session)
            }
        }
        .task {
            await session.restoreStoredSessionIfNeeded()
        }
    }
}
