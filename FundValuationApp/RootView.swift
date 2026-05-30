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

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
