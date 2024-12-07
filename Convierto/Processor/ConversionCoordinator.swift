import Foundation
import UniformTypeIdentifiers
import os.log
import AppKit

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
                    logger.debug("Retry attempt \(attempt + 1) after \(delay/1_000_000_000) seconds")
                    try await Task.sleep(nanoseconds: delay)
                }
                return try await operation()
            } catch {
                lastError = error
                logger.error("Attempt \(attempt + 1) failed: \(error.localizedDescription)")
                resourceManager.cleanup()
            }
        }
        
        logger.error("All retry attempts failed")
        throw lastError ?? ConversionError.conversionFailed(reason: "Max retries exceeded")
    }
    
    private func performConversion(
        url: URL,
        to outputFormat: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        logger.debug("🎬 Starting conversion process")
        logger.debug("📂 Source: \(url.path)")
        logger.debug("🎯 Target format: \(outputFormat.identifier)")
        
        logger.debug("🔍 Determining input type")
        let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey])
        guard let inputType = resourceValues.contentType else {
            logger.error("❌ Failed to determine input type")
            throw ConversionError.invalidInputType
        }
        
        logger.debug("✅ Input type determined: \(inputType.identifier)")
        
        // Handle different conversion types with detailed logging
        if inputType.conforms(to: .audio) && outputFormat.conforms(to: .audiovisualContent) {
            logger.debug("🎵 Initiating audio-to-video conversion")
            let audioProcessor = AudioProcessor()
            logger.debug("✅ Audio processor created")
            return try await audioProcessor.convert(
                url,
                to: outputFormat,
                metadata: metadata,
                progress: progress
            )
        } else if inputType.conforms(to: .image) && outputFormat.conforms(to: .image) {
            logger.debug("🎨 Initiating image-to-image conversion")
            let imageProcessor = ImageProcessor()
            logger.debug("✅ Image processor created")
            return try await imageProcessor.processImage(url, to: outputFormat, metadata: metadata, progress: progress)
} else if inputType.conforms(to: .image) && outputFormat.conforms(to: .movie) {
    logger.debug("🎬 Initiating image-to-video conversion")
            let videoProcessor = VideoProcessor()
            logger.debug("✅ Video processor created")
            
    guard NSImage(contentsOf: url) != nil else {
                logger.error("❌ Failed to load image from URL")
                throw ConversionError.invalidInput
            }
            logger.debug("✅ Image loaded successfully")
            
            return try await videoProcessor.convert(
                url,
                to: outputFormat,
                metadata: metadata,
                progress: progress
            )
        }
        
        logger.error("❌ Unsupported conversion combination")
        logger.debug("📄 Input type: \(inputType.identifier)")
        logger.debug("🎯 Output type: \(outputFormat.identifier)")
        throw ConversionError.conversionNotPossible(reason: "Unsupported conversion type")
    }
} 
