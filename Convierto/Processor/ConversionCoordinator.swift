import Foundation
import UniformTypeIdentifiers
import os.log
import AppKit
import Combine

class ConversionCoordinator: NSObject {
    private let queue = OperationQueue()
    private let maxRetries = 3
    private let resourceManager = ResourceManager.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "ConversionCoordinator")
    private var cancellables = Set<AnyCancellable>()
    
    // Configuration
    private let settings: ConversionSettings
    
    init(settings: ConversionSettings = ConversionSettings()) {
        self.settings = settings
        super.init()
        setupQueue()
        setupQueueMonitoring()
    }
    
    private func setupQueue() {
        queue.maxConcurrentOperationCount = 1  // Serial queue for predictable resource usage
        queue.qualityOfService = .userInitiated
    }
    
    private func setupQueueMonitoring() {
        // Use Combine to monitor queue operations
        queue.publisher(for: \.operationCount)
            .filter { $0 == 0 }
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleQueueEmpty()
            }
            .store(in: &cancellables)
    }
    
    private func handleQueueEmpty() {
        Task {
            await performCleanup()
        }
    }
    
    private func performCleanup() async {
        logger.debug("🧹 Starting cleanup process")
        // Make sure cleanup is actually async
        try? await Task.sleep(nanoseconds: 100_000)  // Small delay to ensure async context
        await resourceManager.cleanup()
        logger.debug("✅ Cleanup completed")
    }
    
    private func performConversion(
        url: URL,
        to outputFormat: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        logger.debug("⚙️ Starting conversion process")
        
        // Determine input type
        let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey])
        guard let inputType = resourceValues.contentType else {
            throw ConversionError.invalidInputType
        }
        
        // Validate conversion compatibility
        let converter = try await createConverter(for: inputType, targetFormat: outputFormat)
        
        // Perform the conversion
        logger.debug("🔄 Converting from \(inputType.identifier) to \(outputFormat.identifier)")
        let result = try await converter.convert(url, to: outputFormat, metadata: metadata, progress: progress)
        
        logger.debug("✅ Conversion completed successfully")
        return result
    }
    
    private func createConverter(
        for inputType: UTType,
        targetFormat: UTType
    ) async throws -> MediaConverting {
        // Select appropriate converter based on input and output types
        if inputType.conforms(to: .image) && targetFormat.conforms(to: .image) {
            return try ImageProcessor(settings: settings)
        } else if inputType.conforms(to: .audiovisualContent) || targetFormat.conforms(to: .audiovisualContent) {
            return try VideoProcessor(settings: settings)
        } else if inputType.conforms(to: .audio) || targetFormat.conforms(to: .audio) {
            return try AudioProcessor(settings: settings)
        } else if inputType.conforms(to: .pdf) || targetFormat.conforms(to: .pdf) {
            return try DocumentProcessor(settings: settings)
        }
        
        throw ConversionError.unsupportedConversion("No converter available for \(inputType.identifier) to \(targetFormat.identifier)")
    }
    
    func convert(
        url: URL,
        to outputFormat: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        let contextId = UUID().uuidString
        logger.debug("🎬 Starting conversion process (Context: \(contextId))")
        
        // Track conversion context
        resourceManager.trackContext(contextId)
        
        defer {
            logger.debug("🔄 Cleaning up conversion context: \(contextId)")
            resourceManager.releaseContext(contextId)
        }
        
        // Validate input before proceeding
        try await validateInput(url: url, targetFormat: outputFormat)
        
        return try await withRetries(
            maxRetries: maxRetries,
            operation: { [weak self] in
                guard let self = self else {
                    throw ConversionError.conversionFailed(reason: "Coordinator was deallocated")
                }
                
                return try await self.performConversion(
                    url: url,
                    to: outputFormat,
                    metadata: metadata,
                    progress: progress
                )
            },
            retryDelay: 1.0
        )
    }
    
    private func validateInput(url: URL, targetFormat: UTType) async throws {
        logger.debug("🔍 Validating input parameters")
        
        // Check if file exists and is readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionError.fileAccessDenied(path: url.path)
        }
        
        // Validate file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0
        
        // Check available memory
        let available = await ResourcePool.shared.getAvailableMemory()
        guard available >= fileSize * 2 else { // Require 2x file size as buffer
            throw ConversionError.insufficientMemory(
                required: fileSize * 2,
                available: available
            )
        }
        
        logger.debug("✅ Input validation successful")
    }
    
    private func withRetries<T>(
        maxRetries: Int,
        operation: @escaping () async throws -> T,
        retryDelay: TimeInterval
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                if attempt > 0 {
                    let delay = calculateRetryDelay(attempt: attempt, baseDelay: retryDelay)
                    logger.debug("⏳ Retry attempt \(attempt + 1) after \(delay) seconds")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                
                return try await operation()
            } catch let error as ConversionError {
                lastError = error
                logger.error("❌ Attempt \(attempt + 1) failed: \(error.localizedDescription)")
                
                // Don't retry certain errors
                if case .invalidInput = error { throw error }
                if case .insufficientMemory = error { throw error }
            } catch {
                lastError = error
                logger.error("❌ Unexpected error in attempt \(attempt + 1): \(error.localizedDescription)")
            }
        }
        
        logger.error("❌ All retry attempts failed")
        throw lastError ?? ConversionError.conversionFailed(reason: "Max retries exceeded")
    }
    
    private func calculateRetryDelay(attempt: Int, baseDelay: TimeInterval) -> TimeInterval {
        let maxDelay: TimeInterval = 30.0 // Maximum delay of 30 seconds
        let delay = baseDelay * pow(2.0, Double(attempt))
        return min(delay, maxDelay)
    }
} 
