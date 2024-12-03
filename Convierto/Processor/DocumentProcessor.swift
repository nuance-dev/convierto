import Foundation
import PDFKit
import UniformTypeIdentifiers
import AppKit

class DocumentProcessor {
    func convert(_ url: URL, to outputFormat: UTType, progress: Progress) async throws -> ProcessingResult {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.documentConversionFailed
        }
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(outputFormat.preferredFilenameExtension ?? "pdf")
        
        do {
            switch outputFormat {
            case .jpeg, .png:
                return try await convertPDFToImage(document, 
                                                 originalURL: url,
                                                 outputFormat: outputFormat,
                                                 outputURL: tempURL,
                                                 progress: progress)
            case .pdf:
                return try await convertToNewPDF(document,
                                               originalURL: url,
                                               outputURL: tempURL,
                                               progress: progress)
            default:
                throw ConversionError.incompatibleFormats
            }
        } catch {
            throw ConversionError.documentConversionFailed
        }
    }
    
    private func convertPDFToImage(_ document: PDFDocument, originalURL: URL, outputFormat: UTType, outputURL: URL, progress: Progress) async throws -> ProcessingResult {
        guard let firstPage = document.page(at: 0) else {
            throw ConversionError.documentConversionFailed
        }
        
        // Create NSImage from PDF page
        let pageRect = firstPage.bounds(for: .mediaBox)
        let renderer = NSImage(size: pageRect.size)
        
        renderer.lockFocus()
        if let context = NSGraphicsContext.current {
            firstPage.draw(with: .mediaBox, to: context.cgContext)
        }
        renderer.unlockFocus()
        
        guard let tiffData = renderer.tiffRepresentation,
              let imageRep = NSBitmapImageRep(data: tiffData) else {
            throw ConversionError.documentConversionFailed
        }
        
        let imageData: Data?
        switch outputFormat {
        case .jpeg:
            imageData = imageRep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        case .png:
            imageData = imageRep.representation(using: .png, properties: [:])
        default:
            throw ConversionError.incompatibleFormats
        }
        
        guard let data = imageData else {
            throw ConversionError.documentConversionFailed
        }
        
        try data.write(to: outputURL)
        
        progress.completedUnitCount = progress.totalUnitCount
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: originalURL.lastPathComponent,
            suggestedFileName: originalURL.deletingPathExtension().lastPathComponent + "." + (outputFormat.preferredFilenameExtension ?? "converted"),
            fileType: outputFormat
        )
    }
    
    private func convertToNewPDF(_ document: PDFDocument, originalURL: URL, outputURL: URL, progress: Progress) async throws -> ProcessingResult {
        guard document.write(to: outputURL) else {
            throw ConversionError.documentConversionFailed
        }
        
        progress.completedUnitCount = progress.totalUnitCount
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: originalURL.lastPathComponent,
            suggestedFileName: originalURL.deletingPathExtension().lastPathComponent + "_converted.pdf",
            fileType: .pdf
        )
    }
}
