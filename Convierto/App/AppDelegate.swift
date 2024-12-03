import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        CacheManager.shared.cleanupOldFiles()
    }
}
