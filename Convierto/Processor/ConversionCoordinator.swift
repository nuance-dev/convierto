import Foundation
import UniformTypeIdentifiers
import os.log

class ConversionCoordinator: NSObject {
    private let queue = OperationQueue()
    private let maxRetries = 3
    private let resourceManager = ResourceManager.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "ConversionCoordinator")
    
    override init() {
        super.init()
        queue.maxConcurrentOperationCount = 1
        setupQueueMonitoring()
    }
    
    private func setupQueueMonitoring() {
        queue.addObserver(self, forKeyPath: "operationCount", options: .new, context: nil)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "operationCount" {
            handleQueueCountChange()
        }
    }
    
    private func handleQueueCountChange() {
        if queue.operationCount == 0 {
            resourceManager.cleanup()
        }
    }
    
    func convert(
        url: URL,
        to outputFormat: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        let contextId = UUID().uuidString
        resourceManager.trackContext(contextId)
        
        defer {
            resourceManager.releaseContext(contextId)
            GraphicsContextManager.shared.releaseContext(for: contextId)
        }
        
        do {
            let result = try await withRetries(maxRetries: maxRetries) { [weak self] in
                guard let self = self else {
                    throw ConversionError.conversionFailed(reason: "Coordinator was deallocated")
                }
                return try await self.performConversion(
                    url: url,
                    to: outputFormat,
                    metadata: metadata,
                    progress: progress
                )
            }
            return result
        } catch {
            logger.error("Conversion failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func createMetadata(for url: URL) async throws -> ConversionMetadata {
        let resourceValues = try url.resourceValues(forKeys: [
            .contentTypeKey,
            .nameKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ])
        
        return ConversionMetadata(
            originalFileName: resourceValues.name,
            originalFileType: resourceValues.contentType,
            creationDate: resourceValues.creationDate,
            modificationDate: resourceValues.contentModificationDate,
            fileSize: Int64(resourceValues.fileSize ?? 0)
        )
    }
    
    private func cleanup() {
        resourceManager.cleanup()
        GraphicsContextManager.shared.releaseAllContexts()
        queue.cancelAllOperations()
    }
    
    private func withRetries<T>(maxRetries: Int, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                if attempt > 0 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                }
                return try await operation()
            } catch {
                lastError = error
                logger.error("Attempt \(attempt + 1) failed: \(error.localizedDescription)")
                resourceManager.cleanup()
            }
        }
        
        throw lastError ?? ConversionError.conversionFailed(reason: "Max retries exceeded")
    }
    
    private func performConversion(
    url: URL,
    to outputFormat: UTType,
    metadata: ConversionMetadata,
    progress: Progress
) async throws -> ProcessingResult {
    let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey])
    guard let inputType = resourceValues.contentType else {
        throw ConversionError.invalidInputType
    }
    
    let processor = await FileProcessor()
    let strategy = try await processor.determineStrategy(from: inputType, to: outputFormat)
    
    // Check system resources before proceeding
    let taskId = UUID()
    try await ResourcePool.shared.checkResourceAvailability(taskId: taskId, type: .conversion(strategy))
    
    return try await processor.processFile(url, outputFormat: outputFormat, metadata: metadata)
}
} 
