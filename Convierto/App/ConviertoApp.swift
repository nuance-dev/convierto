import SwiftUI
import AppKit

@main
struct ConviertoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("isDarkMode") private var isDarkMode = false
    @StateObject private var updater = UpdateChecker()
    @State private var showingUpdateSheet = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 400, minHeight: 500)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .background(WindowAccessor())
                .sheet(isPresented: $showingUpdateSheet) {
                    MenuBarView(updater: updater)
                }
                .onAppear {
                    // Check for updates when app launches
                    updater.checkForUpdates()
                    
                    // Set up observer for update availability
                    updater.onUpdateAvailable = {
                        showingUpdateSheet = true
                    }
                }
                .coordinateSpace(name: "window")
                .clipShape(Rectangle())
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    showingUpdateSheet = true
                    updater.checkForUpdates()
                }
                .keyboardShortcut("U", modifiers: [.command])
                
                if updater.updateAvailable {
                    Button("Download Update") {
                        if let url = updater.downloadURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                
                Divider()
            }
        }
    }
}
