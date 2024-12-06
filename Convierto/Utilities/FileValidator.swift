import Foundation
import UniformTypeIdentifiers

class FileValidator {
    private let maxFileSizes: [UTType: Int64] = [
        .image: 100_000_000,     // 100MB for images
        .audio: 500_000_000,     // 500MB for audio
        .audiovisualContent: 1_000_000_000, // 1GB for video
        .pdf: 200_000_000        // 200MB for PDFs
    ]
    
    func validateFile(_ url: URL) async throws {
        // Check if file exists and is readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionError.invalidInput
        }
        
        // Get file attributes
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        
        // Validate file type
        guard let fileType = resourceValues.contentType else {
            throw ConversionError.invalidInput
        }
        
        // Check file size
        if let fileSize = resourceValues.fileSize {
            let maxSize = getMaxFileSize(for: fileType)
            if fileSize > maxSize {
                throw ConversionError.invalidInput
            }
        }
    }
    
    private func getMaxFileSize(for type: UTType) -> Int64 {
        for (baseType, maxSize) in maxFileSizes {
            if type.conforms(to: baseType) {
                return maxSize
            }
        }
        return 100_000_000 // Default to 100MB
    }
} 