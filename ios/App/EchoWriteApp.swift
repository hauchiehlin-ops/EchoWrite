import SwiftUI

@main
struct EchoWriteApp: App {
    @UIApplicationDelegateAdaptor(EchoWriteAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(processingService: appDelegate.processingService)
        }
    }
}
