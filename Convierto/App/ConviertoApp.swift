import SwiftUI
import AppKit

@main
struct ConviertoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("isDarkMode") private var isDarkMode = false
    @StateObject private var menuBarController = MenuBarController()
    @State private var showingUpdateSheet = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 400, minHeight: 500)
                .preferredColorScheme(isDarkMode ? .dark : .light)
                .background(WindowAccessor())
                .environmentObject(menuBarController)
                .sheet(isPresented: $showingUpdateSheet) {
                    MenuBarView(updater: menuBarController.updater)
                        .environmentObject(menuBarController)
                }
                .onAppear {
                    // Check for updates when app launches
                    menuBarController.updater.checkForUpdates()
                    
                    // Set up observer for update availability
                    menuBarController.updater.onUpdateAvailable = {
                        showingUpdateSheet = true
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    showingUpdateSheet = true
                    menuBarController.updater.checkForUpdates()
                }
                .keyboardShortcut("U", modifiers: [.command])
                
                if menuBarController.updater.updateAvailable {
                    Button("Download Update") {
                        if let url = menuBarController.updater.downloadURL {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                
                Divider()
            }
        }
    }
}
