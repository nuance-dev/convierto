import CoreGraphics
import UniformTypeIdentifiers
import AppKit

// Image Processor Implementation
class ImageProcessor {
    func convert(_ url: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.invalidInput
        }
        
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError.conversionFailed
        }
        
        let outputURL = try CacheManager.shared.createTemporaryURL(for: url.lastPathComponent)
        
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            format.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.conversionFailed
        }
        
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImageDestinationOptimizeColorForSharing: true
        ]
        
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.exportFailed
        }
        
        progress.completedUnitCount = 100
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: url.lastPathComponent,
            suggestedFileName: url.deletingPathExtension().lastPathComponent + "." + (format.preferredFilenameExtension ?? "converted"),
            fileType: format
        )
    }
}
