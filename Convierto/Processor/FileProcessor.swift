import Combine
import Foundation
import UniformTypeIdentifiers
import AppKit
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
    category: "FileProcessor"
)

struct ProcessingResult {
    let outputURL: URL
    let originalFileName: String
    let suggestedFileName: String
    let fileType: UTType
}

@MainActor
class FileProcessor: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var progress: Double = 0
    @Published var processingResult: ProcessingResult?
    
    private let imageProcessor: ImageProcessor
    private let videoProcessor: VideoProcessor
    private let audioProcessor: AudioProcessor
    private let documentProcessor: DocumentProcessor
    private let fileManager = FileManager.default
    private var cancellables = Set<AnyCancellable>()
    
    // Memory management
    private let memoryPressureHandler: MemoryPressureHandler
    private let resourceMonitor: ResourceMonitor
    private let fileValidator: FileValidator
    
    init(settings: ConversionSettings = ConversionSettings()) {
        self.imageProcessor = ImageProcessor(settings: settings)
        self.videoProcessor = VideoProcessor(settings: settings)
        self.audioProcessor = AudioProcessor(settings: settings)
        self.documentProcessor = DocumentProcessor(settings: settings)
        self.memoryPressureHandler = MemoryPressureHandler()
        self.resourceMonitor = ResourceMonitor()
        self.fileValidator = FileValidator()
        
        setupMemoryPressureHandling()
    }
    
    private func setupMemoryPressureHandling() {
        memoryPressureHandler.onPressureChange = { [weak self] (pressure: MemoryPressure) in
            switch pressure {
            case .warning:
                self?.cleanupTemporaryResources()
            case .critical:
                self?.cancelCurrentOperations()
            case .none:
                break
            }
        }
    }
    
    func processFile(_ url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        isProcessing = true
        progress = 0
        
        let monitor = resourceMonitor.startMonitoring()
        defer {
            monitor.stop()
            cleanupTemporaryResources()
        }
        
        do {
            // Validate input file
            try await fileValidator.validateFile(url)
            
            // Get input type and determine strategy
            let inputType = try await getFileType(url)
            let converter = try await determineConverter(for: url, targetFormat: outputFormat)
            let strategy = try converter.validateConversion(from: inputType, to: outputFormat)
            
            // Check resource requirements
            if strategy.requiresBuffering {
                guard resourceMonitor.hasAvailableMemory(required: strategy.estimatedMemoryUsage) else {
                    throw ConversionError.insufficientMemory
                }
            }
            
            // Setup progress tracking
            let progress = Progress(totalUnitCount: 100)
            setupProgressTracking(progress)
            
            // Process with timeout and strategy
            let result = try await withTimeout(seconds: 300) {
                try await self.processWithStrategy(url, to: outputFormat, strategy: strategy, progress: progress)
            }
            
            self.progress = 1.0
            isProcessing = false
            
            return result
        } catch {
            isProcessing = false
            throw error
        }
    }
    
    private func processWithStrategy(_ url: URL, to outputFormat: UTType, strategy: ConversionStrategy, progress: Progress) async throws -> ProcessingResult {
        // Setup progress reporting
        progress.totalUnitCount = 100
        progress.fileOperationKind = .copying
        
        // Pre-conversion checks
        guard resourceMonitor.hasAvailableMemory(required: strategy.estimatedMemoryUsage) else {
            throw ConversionError.insufficientMemory
        }
        
        guard resourceMonitor.hasAvailableDiskSpace else {
            throw ConversionError.insufficientDiskSpace
        }
        
        // Determine converter and validate compatibility
        let converter = try await determineConverter(for: url, targetFormat: outputFormat)
        let fileType = try await getFileType(url)
        guard converter.canConvert(from: fileType, to: outputFormat) else {
            throw ConversionError.incompatibleFormats
        }
        
        // Setup progress monitoring
        let progressMonitor = ProgressMonitor(progress: progress)
        progressMonitor.start()
        
        defer {
            progressMonitor.stop()
            cleanupTemporaryResources()
        }
        
        do {
            // Process with timeout protection
            return try await withThrowingTaskGroup(of: ProcessingResult.self) { group in
                group.addTask {
                    let result = try await converter.convert(url, to: outputFormat, progress: progress)
                    // Verify output
                    try await self.validateOutput(result.outputURL, expectedType: outputFormat)
                    return result
                }
                
                // Wait for result with timeout
                guard let result = try await group.next() else {
                    throw ConversionError.conversionFailed
                }
                
                return result
            }
        } catch {
            throw ConversionError.conversionFailed
        }
    }
    
    private func determineConverter(for url: URL, targetFormat: UTType) async throws -> any MediaConverting {
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
        guard let inputType = resourceValues.contentType else {
            throw ConversionError.invalidInput
        }
        
        // Enhanced conversion logic with smart fallbacks
        switch (inputType, targetFormat) {
        case (let input, let output) where input.conforms(to: .image):
            if output.conforms(to: .audiovisualContent) {
                return videoProcessor // Will handle image-to-video conversion
            } else if output.conforms(to: .pdf) {
                return documentProcessor
            }
            return imageProcessor
            
        case (let input, let output) where input.conforms(to: .audio):
            if output.conforms(to: .audiovisualContent) {
                return videoProcessor // Will create visualization
            } else if output.conforms(to: .image) {
                return imageProcessor // Will create waveform image
            }
            return audioProcessor
            
        case (let input, let output) where input.conforms(to: .audiovisualContent):
            if output.conforms(to: .image) {
                return imageProcessor // Will extract frame
            } else if output.conforms(to: .audio) {
                return audioProcessor // Will extract audio
            }
            return videoProcessor
            
        case (.pdf, _) where targetFormat.conforms(to: .image):
            return documentProcessor
            
        case (let input, .pdf) where input.conforms(to: .image):
            return documentProcessor
            
        default:
            throw ConversionError.incompatibleFormats
        }
    }
    
    private func setupProgressTracking(_ progress: Progress) {
        progress.publisher(for: \.fractionCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.progress = value
            }
            .store(in: &cancellables)
    }
    
    private func cleanupTemporaryResources() {
        try? CacheManager.shared.cleanupOldFiles()
    }
    
    private func cancelCurrentOperations() {
        cancellables.removeAll()
        isProcessing = false
        progress = 0
    }
    
    private func validateOutput(_ url: URL, expectedType: UTType) async throws {
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
        guard let outputType = resourceValues.contentType,
              outputType.conforms(to: expectedType) else {
            throw ConversionError.conversionFailed
        }
    }
    
    private func getFileType(_ url: URL) async throws -> UTType {
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
        guard let contentType = resourceValues.contentType else {
            throw ConversionError.invalidInput
        }
        return contentType
    }
    
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ConversionError.timeout
            }
            
            guard let result = try await group.next() else {
                throw ConversionError.conversionFailed
            }
            
            group.cancelAll()
            return result
        }
    }
}
