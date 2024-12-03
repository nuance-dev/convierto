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
    
    func processFile(_ url: URL, outputFormat: UTType) async throws {
        isProcessing = true
        progress = 0
        
        defer {
            isProcessing = false
        }
        
        do {
            // Validate file size
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            
            if fileSize > 100_000_000 { // 100MB limit
                throw ConversionError.fileTooLarge
            }
            
            // Get file type
            let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
            guard let inputType = resourceValues.contentType else {
                throw ConversionError.invalidInput
            }
            
            // Check if formats are the same
            if inputType == outputFormat {
                throw ConversionError.sameFormat
            }
            
            let progress = Progress(totalUnitCount: 100)
            progress.publisher(for: \.fractionCompleted)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    self?.progress = value
                }
            
            let result = try await convert(
                url: url,
                inputType: inputType,
                outputFormat: outputFormat,
                progress: progress
            )
            
            self.processingResult = result
            self.progress = 1.0
            
        } catch {
            self.progress = 0
            throw error
        }
    }
    
    private func convert(
        url: URL,
        inputType: UTType,
        outputFormat: UTType,
        progress: Progress
    ) async throws -> ProcessingResult {
        if inputType.conforms(to: .image) {
            return try await imageProcessor.convert(url, to: outputFormat, progress: progress)
        } else if inputType.conforms(to: .movie) {
            return try await videoProcessor.convert(url, to: outputFormat, progress: progress)
        } else if inputType.conforms(to: .audio) {
            return try await audioProcessor.convert(url, to: outputFormat, progress: progress)
        } else if inputType.conforms(to: .pdf) {
            return try await documentProcessor.convert(url, to: outputFormat, progress: progress)
        }
        
        throw ConversionError.unsupportedFormat
    }
}
