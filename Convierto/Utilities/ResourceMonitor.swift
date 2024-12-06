import Foundation

class ResourceMonitor {
    class Monitor {
        func stop() {
            // Cleanup monitoring resources
        }
    }
    
    func startMonitoring() -> Monitor {
        return Monitor()
    }
} 