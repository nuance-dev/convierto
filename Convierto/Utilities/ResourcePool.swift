import AppKit
import Foundation

actor ResourcePool {
    static let shared = ResourcePool()
    private var activeTasks: [UUID: TaskInfo] = [:]
    private let queue = OperationQueue()
    private var activeFiles: Set<URL> = []
    private var temporaryFiles: Set<URL> = []
    
    struct TaskInfo {
        let type: ResourceType
        let memoryUsage: UInt64
        let startTime: Date
    }
    
    init() {
        queue.maxConcurrentOperationCount = 2
        setupMemoryPressureHandling()
    }
    
    private nonisolated func setupMemoryPressureHandling() {
        Task { @MainActor in
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { [weak self] in
                    await self?.cleanup(force: true)
                }
            }
        }
    }
    
    func beginTask(id: UUID, type: ResourceType) {
        activeTasks[id] = TaskInfo(
            type: type,
            memoryUsage: type.memoryRequirement,
            startTime: Date()
        )
    }
    
    func endTask(id: UUID) {
        activeTasks.removeValue(forKey: id)
        GraphicsContextManager.shared.releaseContext(for: id.uuidString)
    }
    
    func checkResourceAvailability(taskId: UUID, type: ResourceType) async throws {
        try await checkResources(for: type)
    }
    
    func checkMemoryAvailability(required: UInt64) async throws {
        let availableMemory = ProcessInfo.processInfo.physicalMemory
        guard required < availableMemory * 7 / 10 else {
            throw ConversionError.insufficientMemory(
                required: required,
                available: availableMemory
            )
        }
    }
    
    func canAllocateMemory(bytes: UInt64) -> Bool {
        let availableMemory = ProcessInfo.processInfo.physicalMemory
        let usedMemory = activeTasks.values.reduce(0) { $0 + $1.memoryUsage }
        return (usedMemory + bytes) < availableMemory * 7 / 10
    }
    
    func cleanup(force: Bool = false) async {
        for (id, task) in activeTasks {
            if force || Date().timeIntervalSince(task.startTime) > 3600 { // 1 hour timeout
                endTask(id: id)
            }
        }
    }
    
    private func checkResources(for type: ResourceType) async throws {
        let requiredMemory = type.memoryRequirement
        try await checkMemoryAvailability(required: requiredMemory)
        
        // Check if we have too many active tasks
        if activeTasks.count >= queue.maxConcurrentOperationCount {
            throw ConversionError.resourceExhausted(resource: "Maximum concurrent tasks reached")
        }
    }
    
    func getAvailableMemory() async -> UInt64 {
        let info = ProcessInfo.processInfo
        let totalMemory = info.physicalMemory
        let usedMemory = await getCurrentMemoryUsage()
        return totalMemory - usedMemory
    }
    
    private func getCurrentMemoryUsage() async -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return kerr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    
    func markFileAsActive(_ url: URL) {
        activeFiles.insert(url)
    }
    
    func markFileAsInactive(_ url: URL) {
        activeFiles.remove(url)
    }
    
    func addTemporaryFile(_ url: URL) {
        temporaryFiles.insert(url)
    }
    
    func removeTemporaryFile(_ url: URL) {
        temporaryFiles.remove(url)
    }
    
    func cleanup() {
        for url in temporaryFiles where !activeFiles.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
    }
    
    func getMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
}
