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

class FileProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var processingResult: ProcessingResult?
    
    private let processingQueue = DispatchQueue(label: "com.convierto.processing", qos: .userInitiated)
    private let settings = ConversionSettings()
    
    struct ProcessingResult {
        let outputURL: URL
        let fileName: String
        let originalFileName: String
        let outputFormat: UTType
        
        var suggestedFileName: String {
            let fileURL = URL(fileURLWithPath: originalFileName)
            let filenameWithoutExt = fileURL.deletingPathExtension().lastPathComponent
            let fileExtension = outputFormat.preferredFilenameExtension ?? "converted"
            return "\(filenameWithoutExt)_converted.\(fileExtension)"
        }
    }
    
    @MainActor
    func processFile(_ url: URL, outputFormat: UTType) async throws {
        isProcessing = true
        progress = 0
        processingResult = nil
        
        do {
            let tempURL = try await convertFile(url, to: outputFormat)
            processingResult = ProcessingResult(
                outputURL: tempURL,
                fileName: tempURL.lastPathComponent,
                originalFileName: url.lastPathComponent,
                outputFormat: outputFormat
            )
            progress = 1.0
        } catch {
            isProcessing = false
            progress = 0
            throw error
        }
        
        isProcessing = false
    }
    
    private func convertFile(_ url: URL, to outputFormat: UTType) async throws -> URL {
        let tempURL = try CacheManager.shared.createTemporaryURL(for: url.lastPathComponent)
        
        // Determine input type
        guard let inputType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            throw ConversionError.invalidInput
        }
        
        // Handle different conversion types based on UTType identifiers
        if inputType.conforms(to: .image) && outputFormat.conforms(to: .image) {
            return try await convertImage(from: url, to: tempURL, outputFormat: outputFormat)
        } else if inputType.conforms(to: .video) && outputFormat.conforms(to: .video) {
            return try await convertVideo(from: url, to: tempURL, outputFormat: outputFormat)
        } else if inputType.conforms(to: .audio) && outputFormat.conforms(to: .audio) {
            return try await convertAudio(from: url, to: tempURL, outputFormat: outputFormat)
        } else if inputType.conforms(to: .video) && outputFormat.conforms(to: .audio) {
            return try await extractAudio(from: url, to: tempURL, outputFormat: outputFormat)
        } else if inputType.conforms(to: .pdf) && outputFormat.identifier == "com.microsoft.word.doc" {
            return try await convertPDFToWord(from: url, to: tempURL)
        } else if outputFormat.conforms(to: .pdf) {
            return try await convertToPDF(from: url, to: tempURL)
        } else {
            throw ConversionError.incompatibleFormats
        }
    }
    
    private func convertImage(from url: URL, to tempURL: URL, outputFormat: UTType) async throws -> URL {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.invalidInput
        }
        
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        
        let data: Data?
        switch outputFormat {
        case .png:
            data = bitmapRep.representation(using: .png, properties: [:])
        case .jpeg:
            data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: settings.imageQuality])
        case .tiff:
            data = bitmapRep.representation(using: .tiff, properties: [:])
        case .gif:
            data = bitmapRep.representation(using: .gif, properties: [:])
        case .bmp:
            data = bitmapRep.representation(using: .bmp, properties: [:])
        case .heic:
            if #available(macOS 13.0, *) {
                let ciImage = CIImage(cgImage: cgImage)
                let context = CIContext()
                data = try context.heifRepresentation(
                    of: ciImage,
                    format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB(),
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: settings.imageQuality]
                )
            } else {
                throw ConversionError.unsupportedFormat
            }
        default:
            throw ConversionError.unsupportedFormat
        }
        
        guard let imageData = data else {
            throw ConversionError.conversionFailed
        }
        
        try imageData.write(to: tempURL)
        return tempURL
    }
    
    private func convertVideo(from url: URL, to tempURL: URL, outputFormat: UTType) async throws -> URL {
        let asset = AVURLAsset(url: url)
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: settings.videoQuality
        ) else {
            throw ConversionError.conversionFailed
        }
        
        exportSession.outputURL = tempURL
        
        // Set the appropriate output format
        switch outputFormat.identifier {
        case UTType.mpeg4Movie.identifier:
            exportSession.outputFileType = .mp4
        case UTType.quickTimeMovie.identifier:
            exportSession.outputFileType = .mov
        case UTType.mpeg2Video.identifier:
            exportSession.outputFileType = .m4v
        case "com.microsoft.windows-media-wmv":
            exportSession.outputFileType = AVFileType(rawValue: "com.microsoft.windows-media-wmv")
        case "org.webmproject.webm":
            exportSession.outputFileType = AVFileType(rawValue: "org.webmproject.webm")
        default:
            throw ConversionError.unsupportedFormat
        }
        
        // Configure video settings if available
        if #available(macOS 13.0, *) {
            let videoComposition = AVMutableVideoComposition(asset: asset) { request in
                request.finish(with: request.sourceImage, context: nil)
            }
            exportSession.videoComposition = videoComposition
        }
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed
        }
        
        return tempURL
    }
    
    private func convertAudio(from url: URL, to tempURL: URL, outputFormat: UTType) async throws -> URL {
        let asset = AVURLAsset(url: url)
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ConversionError.conversionFailed
        }
        
        exportSession.outputURL = tempURL
        
        // Set the appropriate output format
        switch outputFormat.identifier {
        case "public.mp3":
            exportSession.outputFileType = .mp3
        case "com.apple.m4a-audio":
            exportSession.outputFileType = .m4a
        case "org.xiph.ogg":
            exportSession.outputFileType = AVFileType(rawValue: "org.xiph.ogg")
        case "com.microsoft.waveform-audio":
            exportSession.outputFileType = .wav
        case "com.apple.coreaudio-format":
            exportSession.outputFileType = .aiff
        default:
            throw ConversionError.unsupportedFormat
        }
        
        // Configure audio settings
        if #available(macOS 13.0, *) {
            let _ = [
                AVEncoderBitRateKey: settings.audioBitRate ?? 128_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            // Audio settings are applied through the preset, no need for explicit mix
        }
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed
        }
        
        return tempURL
    }
    
    private func extractAudio(from url: URL, to tempURL: URL, outputFormat: UTType) async throws -> URL {
        let asset = AVURLAsset(url: url)
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ConversionError.audioExtractionFailed
        }
        
        exportSession.outputURL = tempURL
        
        switch outputFormat {
        case _ where outputFormat.identifier == "public.mp3":
            exportSession.outputFileType = .mp3
        case _ where outputFormat.identifier == "com.apple.m4a-audio":
            exportSession.outputFileType = .m4a
        default:
            throw ConversionError.unsupportedFormat
        }
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed
        }
        
        return tempURL
    }
    
    @available(macOS 13.0, *)
    private func convertToHEIC(cgImage: CGImage) async throws -> Data {
        let context = CIContext()
        let ciImage = CIImage(cgImage: cgImage)
        
        guard let colorSpace = cgImage.colorSpace else {
            throw ConversionError.conversionFailed
        }
        
        let options: [CIImageRepresentationOption: Any] = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: settings.imageQuality
        ]
        
        return try context.heifRepresentation(
            of: ciImage,
            format: .RGBA8,
            colorSpace: colorSpace,
            options: options
        ) ?? Data()
    }
    
    private func convertPDFToWord(from url: URL, to tempURL: URL) async throws -> URL {
        // PDF to Word conversion would require a third-party library or service
        throw ConversionError.documentConversionFailed
    }
    
    private func convertToPDF(from url: URL, to tempURL: URL) async throws -> URL {
        if let document = PDFDocument(url: url) {
            if document.write(to: tempURL) {
                return tempURL
            }
        }
        throw ConversionError.documentConversionFailed
    }
}
