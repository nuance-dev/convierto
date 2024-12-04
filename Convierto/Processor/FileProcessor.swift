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
    
    private let imageProcessor = ImageProcessor()
    private let videoProcessor = VideoProcessor()
    private let audioProcessor = AudioProcessor()
    private let documentProcessor = DocumentProcessor()
    private let fileManager = FileManager.default
    
    func processFile(_ url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        logger.info("Starting file processing for URL: \(url.lastPathComponent)")
        
        await MainActor.run {
            self.isProcessing = true
            self.progress = 0
        }
        
        // Create security-scoped bookmark
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            throw ConversionError.fileAccessDenied
        }
        
        guard resolvedURL.startAccessingSecurityScopedResource() else {
            throw ConversionError.sandboxViolation
        }
        
        defer {
            resolvedURL.stopAccessingSecurityScopedResource()
        }
        
        let resourceValues = try await resolvedURL.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        guard let inputType = resourceValues.contentType else {
            logger.error("Invalid input type for file: \(url.lastPathComponent)")
            throw ConversionError.invalidInput
        }
        
        logger.debug("Input type: \(inputType.identifier), Output format: \(outputFormat.identifier)")
        
        if let fileSize = resourceValues.fileSize {
            logger.debug("File size: \(fileSize) bytes")
            if fileSize > 100_000_000 {
                logger.error("File too large: \(fileSize) bytes")
                throw ConversionError.fileTooLarge
            }
        }
        
        if inputType == outputFormat {
            logger.notice("Input and output formats are identical: \(inputType.identifier)")
            throw ConversionError.sameFormat
        }
        
        let progress = Progress(totalUnitCount: 100)
        progress.publisher(for: \.fractionCompleted)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.progress = value
            }
            .store(in: &cancellables)
        
        do {
            let result: ProcessingResult
            
            switch (inputType, outputFormat) {
            // Audio to Video conversion
            case (let input, let output) where input.conforms(to: .audio) && output.conforms(to: .audiovisualContent):
                result = try await audioProcessor.convert(resolvedURL, to: outputFormat, progress: progress)
                
            // Video to Audio extraction
            case (let input, let output) where input.conforms(to: .audiovisualContent) && output.conforms(to: .audio):
                result = try await videoProcessor.convert(resolvedURL, to: outputFormat, progress: progress)
                
            // Image to Video conversion
            case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .audiovisualContent):
                result = try await imageProcessor.convert(resolvedURL, to: outputFormat, progress: progress)
                
            // Video to Image sequence
            case (let input, let output) where input.conforms(to: .audiovisualContent) && output.conforms(to: .image):
                result = try await videoProcessor.convert(resolvedURL, to: outputFormat, progress: progress)
                
            // Standard conversions
            case (let input, _) where input.conforms(to: .audio):
                result = try await audioProcessor.convert(resolvedURL, to: outputFormat, progress: progress)
            case (let input, _) where input.conforms(to: .audiovisualContent):
                result = try await videoProcessor.convert(resolvedURL, to: outputFormat, progress: progress)
            case (let input, _) where input.conforms(to: .image):
                result = try await imageProcessor.convert(resolvedURL, to: outputFormat, progress: progress)
            default:
                throw ConversionError.incompatibleFormats
            }
            
            return result
        } catch {
            logger.error("Conversion failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
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
