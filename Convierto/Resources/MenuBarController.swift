import SwiftUI
import AppKit

class MenuBarController: NSObject, ObservableObject {
    @Published private(set) var updater = UpdateChecker()
    private var statusItem: NSStatusItem!
    
    override init() {
        super.init()
        
        // Initialize status item on main queue
        DispatchQueue.main.async {
            self.setupMenuBar()
            self.updater.checkForUpdates()
        }
    }
    
    private func setupMenuBar() {
        // Create the status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Update Status")
            
            // Create the menu
            let menu = NSMenu()
            menu.delegate = self
            
            // Set the menu
            statusItem.menu = menu
            
            // Update the button image when the status changes
            updater.onStatusChange = { [weak self] newIcon in
                guard self != nil else { return }
                DispatchQueue.main.async {
                    button.image = NSImage(systemSymbolName: newIcon, accessibilityDescription: "Update Status")
                }
            }
        }
    }
    
    @objc private func checkForUpdates() {
        updater.checkForUpdates()
    }
    
    @objc private func downloadUpdate() {
        if let url = updater.downloadURL {
            NSWorkspace.shared.open(url)
        }
    }
}

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Clear existing items
        menu.removeAllItems()
        
        // Add version
        let versionItem = NSMenuItem(title: "Convierto v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Add status
        if updater.isChecking {
            let checkingItem = NSMenuItem(title: "Checking for updates...", action: nil, keyEquivalent: "")
            checkingItem.isEnabled = false
            menu.addItem(checkingItem)
        } else if updater.updateAvailable {
            if let version = updater.latestVersion {
                let availableItem = NSMenuItem(title: "Version \(version) Available", action: nil, keyEquivalent: "")
                availableItem.isEnabled = false
                menu.addItem(availableItem)
            }
            let downloadItem = NSMenuItem(title: "Download Update", action: #selector(downloadUpdate), keyEquivalent: "")
            downloadItem.target = self
            menu.addItem(downloadItem)
        } else {
            let upToDateItem = NSMenuItem(title: "App is up to date", action: nil, keyEquivalent: "")
            upToDateItem.isEnabled = false
            menu.addItem(upToDateItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        
        // Add check for updates item
        let checkItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "u")
        checkItem.target = self
        menu.addItem(checkItem)
    }
    
    func menuDidClose(_ menu: NSMenu) {
        // Optional: Handle menu closing
    }
    
    func numberOfItems(in menu: NSMenu) -> Int {
        // Let the menu build dynamically
        return menu.numberOfItems
    }
}
