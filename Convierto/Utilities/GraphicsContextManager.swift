import CoreImage
import Foundation
import os.log

class GraphicsContextManager {
    static let shared = GraphicsContextManager()
    private let queue = DispatchQueue(label: "com.convierto.graphics", qos: .userInitiated)
    private var contexts: [String: (context: CIContext, lastUsed: Date)] = [:]
    private let lock = NSLock()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "GraphicsContextManager")
    
    private let maxContexts = 3
    private let contextTimeout: TimeInterval = 30
    private let options: [CIContextOption: Any] = [
        .cacheIntermediates: false,
        .allowLowPower: true,
        .priorityRequestLow: true
    ]
    
    private init() {
        setupContextCleanupTimer()
    }
    
    private func setupContextCleanupTimer() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.cleanupUnusedContexts()
        }
    }
    
    func context(for key: String) -> CIContext {
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = contexts[key] {
            contexts[key] = (existing.context, Date())
            return existing.context
        }
        
        cleanupUnusedContexts()
        
        let context = CIContext(options: options)
        contexts[key] = (context, Date())
        return context
    }
    
    func releaseContext(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        
        contexts.removeValue(forKey: key)
    }
    
    private func cleanupUnusedContexts() {
        let now = Date()
        contexts = contexts.filter { key, value in
            if now.timeIntervalSince(value.lastUsed) > contextTimeout {
                logger.debug("Releasing unused context: \(key)")
                return false
            }
            return true
        }
    }
    
    func releaseAllContexts() {
        lock.lock()
        defer { lock.unlock() }
        
        contexts.removeAll()
    }
    
    func monitorMemoryPressure() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let observer = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
            observer.setEventHandler { [weak self] in
                self?.handleMemoryPressure()
            }
            observer.resume()
        }
    }
    
    private func handleMemoryPressure() {
        lock.lock()
        defer { lock.unlock() }
        
        // Release all contexts except the most recently used one
        let sortedContexts = contexts.sorted { $0.value.lastUsed > $1.value.lastUsed }
        if sortedContexts.count > 1 {
            for (key, _) in sortedContexts[1...] {
                contexts.removeValue(forKey: key)
            }
        }
        
        logger.debug("Memory pressure handled: released \(sortedContexts.count - 1) contexts")
    }
    
    func releaseContextSync(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        contexts.removeValue(forKey: key)
    }
}