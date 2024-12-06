import Foundation

enum MemoryPressure {
    case none
    case warning
    case critical
}

class MemoryPressureHandler {
    var onPressureChange: ((MemoryPressure) -> Void)?
    private var observation: NSObjectProtocol?
    private var timer: Timer?
    
    init() {
        setupObserver()
        startMonitoring()
    }
    
    deinit {
        if let observation = observation {
            NotificationCenter.default.removeObserver(observation)
        }
        timer?.invalidate()
    }
    
    private func setupObserver() {
        observation = NotificationCenter.default.addObserver(
            forName: .memoryPressureWarning,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onPressureChange?(.warning)
        }
    }
    
    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkMemoryPressure()
        }
    }
    
    private func checkMemoryPressure() {
        let hostPort = mach_host_self()
        var hostSize = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var hostInfo = vm_statistics64_data_t()
        
        let result = withUnsafeMutablePointer(to: &hostInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(hostSize)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &hostSize)
            }
        }
        
        if result == KERN_SUCCESS {
            let totalMemory = Int64(hostInfo.wire_count + hostInfo.active_count + hostInfo.inactive_count + hostInfo.free_count) * Int64(vm_page_size)
            let freeMemory = Int64(hostInfo.free_count) * Int64(vm_page_size)
            let usedPercentage = Double(totalMemory - freeMemory) / Double(totalMemory)
            
            if usedPercentage > 0.9 {
                onPressureChange?(.critical)
            } else if usedPercentage > 0.8 {
                onPressureChange?(.warning)
            } else {
                onPressureChange?(.none)
            }
        }
    }
} 