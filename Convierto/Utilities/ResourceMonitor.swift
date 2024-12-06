import Foundation

class ResourceMonitor {
    private let minimumMemory: Int64 = 500_000_000 // 500MB
    private let minimumDiskSpace: Int64 = 1_000_000_000 // 1GB
    
    func hasAvailableMemory(required amount: Int64) -> Bool {
        let hostPort = mach_host_self()
        var hostSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var hostInfo = vm_statistics64_data_t()
        
        let result = withUnsafeMutablePointer(to: &hostInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(hostSize)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &hostSize)
            }
        }
        
        if result == KERN_SUCCESS {
            let freeMemory = Int64(hostInfo.free_count) * Int64(vm_page_size)
            return freeMemory >= amount
        }
        
        return true // Default to true if we can't get memory info
    }
    
    var hasAvailableDiskSpace: Bool {
        guard let volumeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return true
        }
        
        do {
            let values = try volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let capacity = values.volumeAvailableCapacity {
                return capacity >= minimumDiskSpace
            }
        } catch {
            // Log error but don't fail
            print("Error checking disk space: \(error)")
        }
        
        return true // Default to true if we can't get disk space info
    }
    
    func startMonitoring() -> MonitoringSession {
        return MonitoringSession()
    }
}

class MonitoringSession {
    private var timer: Timer?
    
    init() {
        startTimer()
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkResources()
        }
    }
    
    private func checkResources() {
        let pressure = ProcessInfo.processInfo.systemUptime
        if pressure > 0.8 {
            NotificationCenter.default.post(name: .memoryPressureWarning, object: nil)
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
} 