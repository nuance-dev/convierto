import Combine
import Foundation
import UniformTypeIdentifiers
import AppKit
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
    category: "FileProcessor"
)

enum ConversionError: LocalizedError {
    case unsupportedFormat
    case conversionFailed
    case invalidInput
    case incompatibleFormats
    case exportFailed
    case fileTooLarge
    case conversionTimeout
    case verificationFailed
    case sameFormat
    case documentConversionFailed
    case fileAccessDenied
    case sandboxViolation
    case processingFailed
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file type isn't supported yet"
        case .conversionFailed:
            return "Unable to convert this file. Please try another format."
        case .invalidInput:
            return "This file appears to be damaged or inaccessible"
        case .incompatibleFormats:
            return "Can't convert between these formats"
        case .exportFailed:
            return "Unable to save the converted file"
        case .fileTooLarge:
            return "File is too large (max 100MB)"
        case .conversionTimeout:
            return "Conversion is taking too long"
        case .verificationFailed:
            return "The converted file appears to be invalid"
        case .sameFormat:
            return "File is already in this format"
        case .documentConversionFailed:
            return "Failed to convert document. Please try a different format."
        case .fileAccessDenied:
            return "Unable to access the file. Please check permissions."
        case .sandboxViolation:
            return "Cannot access this file due to system security. Try moving it to a different location."
        case .processingFailed:
            return "Failed to process the media file"
        case .timeout:
            return "Conversion timed out"
        }
    }
}

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
    private let memoryPressureHandler = MemoryPressureHandler()
    private let resourceMonitor = ResourceMonitor()
    
    init() {
        let settings = ConversionSettings()
        self.imageProcessor = ImageProcessor(settings: settings)
        self.videoProcessor = VideoProcessor(settings: settings)
        self.audioProcessor = AudioProcessor(settings: settings)
        self.documentProcessor = DocumentProcessor(settings: settings)
        
        setupMemoryPressureHandling()
    }
    
    private func setupMemoryPressureHandling() {
        memoryPressureHandler.onPressureChange = { [weak self] pressure in
            switch pressure {
            case .warning:
                self?.cleanupTemporaryResources()
            case .critical:
                self?.cancelCurrentOperations()
            default:
                break
            }
        }
    }
    
    func processFile(_ url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        logger.info("Starting file processing for URL: \(url.lastPathComponent)")
        
        await MainActor.run {
            self.isProcessing = true
            self.progress = 0
        }
        
        // Resource monitoring
        let monitor = resourceMonitor.startMonitoring()
        defer {
            monitor.stop()
            cleanupTemporaryResources()
        }
        
        do {
            let result = try await processFileWithValidation(url, outputFormat: outputFormat)
            await MainActor.run {
                self.progress = 1.0
                self.isProcessing = false
            }
            return result
        } catch {
            await MainActor.run {
                self.isProcessing = false
            }
            throw error
        }
    }
    
    private func processFileWithValidation(_ url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        // Validate input file
        let validator = FileValidator()
        try await validator.validateFile(url)
        
        // Determine conversion type and process
        let converter = try await determineConverter(for: url, targetFormat: outputFormat)
        
        // Setup progress tracking
        let progress = Progress(totalUnitCount: 100)
        setupProgressTracking(progress)
        
        // Process with timeout protection
        return try await withTimeout(seconds: 300) {
            try await converter.convert(url, to: outputFormat, progress: progress)
        }
    }
    
    private func determineConverter(for url: URL, targetFormat: UTType) async throws -> MediaConverting {
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
        guard let inputType = resourceValues.contentType else {
            throw ConversionError.invalidInput
        }
        
        // Enhanced conversion logic
        switch (inputType, targetFormat) {
        case (let input, let output) where input.conforms(to: .image):
            if output.conforms(to: .audiovisualContent) {
                return videoProcessor
            }
            return imageProcessor
            
        case (let input, let output) where input.conforms(to: .audio):
            if output.conforms(to: .audiovisualContent) {
                return videoProcessor
            }
            return audioProcessor
            
        case (let input, let output) where input.conforms(to: .audiovisualContent):
            if output.conforms(to: .image) {
                return imageProcessor
            } else if output.conforms(to: .audio) {
                return audioProcessor
            }
            return videoProcessor
            
        case (.pdf, _), (_, .pdf):
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
}

// MARK: - Format Validation
extension FileProcessor {
    func validateFormat(_ format: UTType, for operation: String) -> Bool {
        logger.debug("Validating format: \(format.identifier) for operation: \(operation)")
        let supported = supportedFormats(for: operation).contains(format)
        logger.debug("Format \(format.identifier) supported: \(supported)")
        return supported
    }
    
    private func supportedFormats(for operation: String) -> Set<UTType> {
        switch operation {
        case "input":
            return [.jpeg, .png, .pdf, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
        case "output":
            return [.jpeg, .png, .pdf, .mpeg4Movie, .mp3, .wav]
        default:
            return []
        }
    }
}

// Helper for timeout
func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ConversionError.conversionTimeout
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
