import SwiftUI
import Combine

@main
struct TranscodaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Empty - AppDelegate handles window creation manually
        Settings { EmptyView() }
    }
}

// MARK: - Launch URL relay

class LaunchURLs: ObservableObject {
    @Published var urls: [URL] = []
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let launchURLs = LaunchURLs()
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Parse file paths passed as arguments from Automator
        let urls = CommandLine.arguments
            .dropFirst()
            .map { URL(fileURLWithPath: $0) }

        if !urls.isEmpty {
            launchURLs.urls = urls
        }

        openMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openMainWindow() {
        let contentView = ContentView()
            .environmentObject(launchURLs)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 790),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Transcoda"
        window.contentView = NSHostingView(rootView: contentView)
        window.minSize = NSSize(width: 580, height: 520)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
