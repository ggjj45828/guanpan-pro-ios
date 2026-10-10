import SwiftUI

@main
struct GuanpanProApp: App {
    @UIApplicationDelegateAdaptor(GuanpanAppDelegate.self) private var appDelegate
    @StateObject private var store = PortfolioStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(store.appearance == .dark ? .dark : store.appearance == .light ? .light : nil)
                .onAppear { BackgroundQuoteRefresh.configure(store: store) }
        }
    }
}
