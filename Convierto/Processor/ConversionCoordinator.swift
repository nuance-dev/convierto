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
    
    private var activeConversions = Set<UUID>()
    private let activeConversionsQueue = DispatchQueue(label: "com.convierto.activeConversions")
    
    // Add a property to track active processing
    private var isProcessing: Bool = false
    private let processingQueue = DispatchQueue(label: "com.convierto.processing")
    
    init(settings: ConversionSettings = ConversionSettings()) {
        self.settings = settings
        super.init()
        setupQueue()
        setupQueueMonitoring()
        ProcessorFactory.setupShared(coordinator: self, settings: settings)
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
        processingQueue.sync {
            // Only perform cleanup if we're not processing and have no active conversions
            if !isProcessing && activeConversions.isEmpty {
                // Add a longer delay to ensure all processes are complete
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 second delay
                    // Double check that we're still not processing
                    if !self.isProcessing && self.activeConversions.isEmpty {
                        await performCleanup()
                    }
                }
            }
        }
    }
    
    func trackConversion(_ id: UUID) async {
        logger.debug("📝 Tracking conversion: \(id.uuidString)")
        await withCheckedContinuation { continuation in
            activeConversionsQueue.async {
                self.activeConversions.insert(id)
                continuation.resume()
            }
        }
    }
    
    func untrackConversion(_ id: UUID) async {
        logger.debug("🗑 Untracking conversion: \(id.uuidString)")
        await withCheckedContinuation { continuation in
            activeConversionsQueue.async {
                self.activeConversions.remove(id)
                // Only schedule cleanup if this was the last conversion
                if self.activeConversions.isEmpty {
                    Task {
                        // Increase delay before cleanup
                        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 second delay
                        // Double check active conversions and processing state
                        if self.activeConversions.isEmpty && !self.isProcessing {
                            await self.performCleanup()
                        }
                    }
                }
                continuation.resume()
            }
        }
    }
    
    private func performCleanup() async {
        // Check one final time before cleanup
        guard await shouldPerformCleanup() else {
            logger.debug("🚫 Skipping cleanup - active processing detected")
            return
        }
        
        logger.debug("🧹 Starting cleanup process")
        try? await Task.sleep(nanoseconds: 100_000)
        await resourceManager.cleanup()
        logger.debug("✅ Cleanup completed")
    }
    
    private func shouldPerformCleanup() async -> Bool {
        await withCheckedContinuation { continuation in
            processingQueue.sync {
                continuation.resume(returning: !isProcessing && activeConversions.isEmpty)
            }
        }
    }
    
    private func performConversion(
        url: URL,
        to outputFormat: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        processingQueue.sync { isProcessing = true }
        defer {
            processingQueue.sync { isProcessing = false }
        }
        
        let conversionId = UUID()
        logger.debug("🔄 Starting conversion process: \(conversionId.uuidString)")
        
        // Get input type before conversion
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
        guard let inputType = resourceValues.contentType else {
            throw ConversionError.invalidInput
        }
        
        return try await withThrowingTaskGroup(of: ProcessingResult.self) { group in
            group.addTask {
                // Track conversion
                await self.trackConversion(conversionId)
                
                defer {
                    Task {
                        await self.untrackConversion(conversionId)
                    }
                }
                
                let converter = try await self.createConverter(for: inputType, targetFormat: outputFormat)
                let result = try await converter.convert(url, to: outputFormat, metadata: metadata, progress: progress)
                
                // Add delay before cleanup
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                
                return result
            }
            
            let result = try await group.next()
            if let result = result {
                return result
            } else {
                throw ConversionError.conversionFailed(reason: "Conversion failed to complete")
            }
        }
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
