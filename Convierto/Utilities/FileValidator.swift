import Foundation
import UniformTypeIdentifiers

class FileValidator {
    private let maxFileSizes: [UTType: Int64] = [
        .image: 500_000_000,     // 500MB for images
        .audio: 1_000_000_000,   // 1GB for audio
        .audiovisualContent: 2_000_000_000, // 2GB for video
        .pdf: 500_000_000        // 500MB for PDFs
    ]
    
    func validateFile(_ url: URL) async throws {
        // Check if file exists and is readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionError.invalidInput
        }
        
        // Get file attributes
        let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        
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
