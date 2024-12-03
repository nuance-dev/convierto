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
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file format is not supported"
        case .conversionFailed:
            return "Failed to convert the file"
        case .invalidInput:
            return "The input file is invalid or corrupted"
        case .incompatibleFormats:
            return "Cannot convert between these formats"
        case .exportFailed:
            return "Failed to export the converted file"
        case .audioExtractionFailed:
            return "Failed to extract audio from the file"
        case .documentConversionFailed:
            return "Failed to convert the document"
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
    
    // Define supported types and their conversion targets
    private let supportedTypes: [UTType: Set<UTType>] = [
        .image: [.jpeg, .png, .tiff, .gif, .bmp, .webP, .heic],
        .movie: [.mpeg4Movie, .quickTimeMovie, .avi],
        .audio: [.mp3, .wav, .aiff, .mpeg4Audio],
        .pdf: [.jpeg, .png, .pdf]
    ]
    
    func processFile(_ url: URL, outputFormat: UTType) async throws {
        isProcessing = true
        progress = 0
        
        defer { 
            isProcessing = false
        }
        
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
        let inputType = resourceValues.contentType ?? .item
        
        // Find matching base type
        let baseType = supportedTypes.keys.first { type in
            inputType.conforms(to: type) || 
            supportedTypes[type]?.contains(inputType) == true
        }
        
        guard let baseType = baseType else {
            throw ConversionError.unsupportedFormat
        }
        
        // Validate output format
        guard let supportedOutputs = supportedTypes[baseType],
              supportedOutputs.contains(outputFormat) else {
            throw ConversionError.incompatibleFormats
        }
        
        let result = try await withProgress { progress in
            switch baseType {
            case .image:
                return try await self.imageProcessor.convert(url, to: outputFormat, progress: progress) // Must have self, keep this comment so we don't forget
            case .movie:
                return try await self.videoProcessor.convert(url, to: outputFormat, progress: progress) // Must have self, keep this comment so we don't forget
            case .audio:
                return try await self.audioProcessor.convert(url, to: outputFormat, progress: progress) // Must have self, keep this comment so we don't forget
            case .pdf:
                return try await self.documentProcessor.convert(url, to: outputFormat, progress: progress) // Must have self, keep this comment so we don't forget
            default:
                throw ConversionError.unsupportedFormat
            }
        }
        
        self.processingResult = result
        self.progress = 1.0
    }
    
    private func withProgress<T>(_ operation: @escaping (Progress) async throws -> T) async throws -> T {
        let progress = Progress(totalUnitCount: 100)
        
        let observation = progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.progress = progress.fractionCompleted
            }
        }
        
        defer {
            observation.invalidate()
        }
        
        do {
            return try await operation(progress)
        } catch {
            self.progress = 0
            throw error
        }
    }
}
