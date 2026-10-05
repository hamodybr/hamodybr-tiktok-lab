import SwiftUI

@main
struct HAMODYBRTikTokLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(\.layoutDirection, .rightToLeft)
        }
    }
}
