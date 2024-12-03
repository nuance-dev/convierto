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

class FileProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var processingResult: ProcessingResult?
    
    private let imageProcessor = ImageProcessor()
    private let videoProcessor = VideoProcessor()
    private let audioProcessor = AudioProcessor()
    private let documentProcessor = DocumentProcessor()
    
    func processFile(_ url: URL, outputFormat: UTType) async throws {
        isProcessing = true
        progress = 0
        defer { isProcessing = false }
        
        let inputType = try await url.resourceValues(forKeys: [.contentTypeKey]).contentType ?? .item
        
        guard isConversionSupported(from: inputType, to: outputFormat) else {
            throw ConversionError.incompatibleFormats
        }
        
        let result = try await withProgress { progress in
            switch true {
            case inputType.conforms(to: .image):
                return try await self.imageProcessor.convert(url, to: outputFormat, progress: progress)
            case inputType.conforms(to: .movie):
                return try await self.videoProcessor.convert(url, to: outputFormat, progress: progress)
            case inputType.conforms(to: .audio):
                return try await self.audioProcessor.convert(url, to: outputFormat, progress: progress)
            case inputType.conforms(to: .pdf):
                return try await self.documentProcessor.convert(url, to: outputFormat, progress: progress)
            default:
                throw ConversionError.unsupportedFormat
            }
        }
        
        await MainActor.run {
            self.processingResult = result
        }
    }
    
    private func withProgress<T>(_ operation: @escaping (Progress) async throws -> T) async throws -> T {
        let progress = Progress(totalUnitCount: 100)
        
        let observation = progress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in
                self.progress = progress.fractionCompleted
            }
        }
        
        defer {
            observation.invalidate()
        }
        
        return try await operation(progress)
    }
    
    private func isConversionSupported(from input: UTType, to output: UTType) -> Bool {
        let supportedConversions: [UTType: Set<UTType>] = [
            .image: [.jpeg, .png, .tiff, .gif, .bmp, .webP, .heic],
            .movie: [.mpeg4Movie, .quickTimeMovie, .avi],
            .audio: [.mp3, .wav, .aiff, .mpeg4Audio],
            .pdf: [.jpeg, .png, .pdf]
        ]
        
        guard let baseType = supportedConversions.keys.first(where: { input.conforms(to: $0) }),
              let supportedOutputs = supportedConversions[baseType] else {
            return false
        }
        
        return supportedOutputs.contains(output)
    }
}