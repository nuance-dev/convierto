import Foundation
import PDFKit
import UniformTypeIdentifiers
import AppKit
import CoreGraphics
import AVFoundation
import CoreMedia

enum ConversionError: LocalizedError {
    case unsupportedFormat
    case conversionFailed
    case invalidInput
    case incompatibleFormats
    case exportFailed
    case audioExtractionFailed
    case documentConversionFailed
    case fileAccessDenied
    case securityScopedResourceFailed
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file format is not supported"
        case .conversionFailed:
            return "Failed to convert the file"
        case .invalidInput:
            return "The file appears to be corrupted or inaccessible"
        case .incompatibleFormats:
            return "Cannot convert between these formats"
        case .exportFailed:
            return "Failed to export the converted file"
        case .audioExtractionFailed:
            return "Failed to extract audio from the file"
        case .documentConversionFailed:
            return "Failed to convert the document"
        case .fileAccessDenied:
            return "Cannot access the file. Please check permissions"
        case .securityScopedResourceFailed:
            return "Cannot access the file due to security restrictions"
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
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var processingResult: ProcessingResult?
    
    private let imageProcessor = ImageProcessor()
    private let videoProcessor = VideoProcessor()
    private let audioProcessor = AudioProcessor()
    private let documentProcessor = DocumentProcessor()
    
    private let supportedTypes: [UTType: Set<UTType>] = [
        .image: [.jpeg, .png, .tiff, .gif, .bmp, .webP, .heic],
        .movie: [.mpeg4Movie, .quickTimeMovie, .avi],
        .audio: [.mp3, .wav, .aiff, .mpeg4Audio],
        .pdf: [.jpeg, .png, .pdf]
    ]
    
    func processFile(_ url: URL, outputFormat: UTType) async throws {
        await setProcessingState(true)
        defer {
            Task { @MainActor in
                self.isProcessing = false
            }
        }
        
        do {
            let result = try await processFileInternal(url: url, outputFormat: outputFormat)
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
    }
    
    private func setProcessingState(_ state: Bool) async {
        await MainActor.run {
            self.isProcessing = state
            self.progress = 0
        }
    }
    
    private func processFileInternal(url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey, .isReadableKey])
        guard let inputType = resourceValues.contentType,
              resourceValues.isReadable == true else {
            throw ConversionError.fileAccessDenied
        }
        
        let baseType = supportedTypes.keys.first { type in
            inputType.conforms(to: type) || 
            supportedTypes[type]?.contains(inputType) == true
        }
        
        guard let baseType = baseType else {
            throw ConversionError.unsupportedFormat
        }
        
        guard let supportedOutputs = supportedTypes[baseType],
              supportedOutputs.contains(outputFormat) else {
            throw ConversionError.incompatibleFormats
        }
        
        let progress = Progress(totalUnitCount: 100)
        let progressObserver = progress.observe(\.fractionCompleted) { [weak self] _, _ in
            Task { @MainActor in
                self?.progress = progress.fractionCompleted
            }
        }
        
        defer {
            progressObserver.invalidate()
        }
        
        let result = try await {
            switch baseType {
            case .image:
                return try await imageProcessor.convert(url, to: outputFormat, progress: progress)
            case .movie:
                return try await videoProcessor.convert(url, to: outputFormat, progress: progress)
            case .audio:
                return try await audioProcessor.convert(url, to: outputFormat, progress: progress)
            case .pdf:
                return try await documentProcessor.convert(url, to: outputFormat, progress: progress)
            default:
                throw ConversionError.unsupportedFormat
            }
        }()
        
        return result
    }
}
