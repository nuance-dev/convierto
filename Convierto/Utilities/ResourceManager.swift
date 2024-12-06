import Foundation
import AppKit
import os.log

class ResourceManager {
    static let shared = ResourceManager()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "ResourceManager")
    
    private let memoryLimit: UInt64 = 1024 * 1024 * 1024 // 1GB
    private var activeContexts: Set<String> = []
    private let queue = DispatchQueue(label: "com.convierto.resources")
    private let lock = NSLock()
    
    private var memoryWarningObserver: NSObjectProtocol?
    
    init() {
        setupMemoryWarningObserver()
    }
    
    func canAllocateMemory(bytes: UInt64) -> Bool {
        let free = ProcessInfo.processInfo.physicalMemory
        return bytes < free / 2
    }
    
    func trackContext(_ identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        activeContexts.insert(identifier)
    }
    
    func releaseContext(_ identifier: String) {
        lock.lock()
        defer { lock.unlock() }
        activeContexts.remove(identifier)
        GraphicsContextManager.shared.releaseContext(for: identifier)
    }
    
    func cleanup() {
        lock.lock()
        defer { lock.unlock() }
        
        activeContexts.forEach { contextId in
            GraphicsContextManager.shared.releaseContext(for: contextId)
        }
        activeContexts.removeAll()
    }
    
    private func setupMemoryWarningObserver() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }
    
    private func handleMemoryWarning() {
        logger.warning("Memory warning received, cleaning up resources")
        cleanup()
    }
    
    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
} 