import Foundation

class FileValidator {
    func validateFile(_ url: URL) async throws {
        let fileManager = FileManager.default
        
        // Check if file exists
        guard fileManager.fileExists(atPath: url.path) else {
            throw ConversionError.invalidInput
        }
        
        // Check file size
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0
        if fileSize > 100_000_000 { // 100MB limit
            throw ConversionError.fileTooLarge
        }
        
        // Verify file is readable
        guard fileManager.isReadableFile(atPath: url.path) else {
            throw ConversionError.fileAccessDenied
        }
    }
} 