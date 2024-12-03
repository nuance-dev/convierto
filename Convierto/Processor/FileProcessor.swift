import Foundation
import UniformTypeIdentifiers
import AppKit

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
    
    func processFile(_ url: URL, outputFormat: UTType) async throws {
        isProcessing = true
        progress = 0
        
        do {
            let result = try await processFileInternal(url, outputFormat: outputFormat)
            await MainActor.run {
                self.processingResult = result
                self.progress = 1.0
            }
        } catch {
            await MainActor.run {
                self.progress = 0
            }
            throw error
        }
        
        await MainActor.run {
            self.isProcessing = false
        }
    }
    
    private func processFileInternal(_ url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw ConversionError.fileAccessDenied
        }
        
        guard url.startAccessingSecurityScopedResource() else {
            throw ConversionError.sandboxViolation
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        guard let inputType = resourceValues.contentType else {
            throw ConversionError.invalidInput
        }
        
        if let fileSize = resourceValues.fileSize, fileSize > 100_000_000 {
            throw ConversionError.fileTooLarge
        }
        
        if inputType == outputFormat {
            throw ConversionError.sameFormat
        }
        
        let progress = Progress(totalUnitCount: 100)
        
        // Create a separate task for progress monitoring
        let progressTask = Task { @MainActor in
            for await value in progress.publisher(for: \.fractionCompleted).values {
                self.progress = value
            }
        }
        
        defer {
            progressTask.cancel()
        }
        
        return try await convert(
            url: url,
            inputType: inputType,
            outputFormat: outputFormat,
            progress: progress
        )
    }
    
    private func convert(
        url: URL,
        inputType: UTType,
        outputFormat: UTType,
        progress: Progress
    ) async throws -> ProcessingResult {
        try await withTimeout(seconds: 300) { // 5 minute timeout
            if inputType.conforms(to: .image) {
                return try await self.imageProcessor.convert(url, to: outputFormat, progress: progress)
            } else if inputType.conforms(to: .movie) {
                return try await self.videoProcessor.convert(url, to: outputFormat, progress: progress)
            } else if inputType.conforms(to: .audio) {
                return try await self.audioProcessor.convert(url, to: outputFormat, progress: progress)
            } else if inputType.conforms(to: .pdf) {
                return try await self.documentProcessor.convert(url, to: outputFormat, progress: progress)
            }
            throw ConversionError.unsupportedFormat
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
