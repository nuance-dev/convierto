import Foundation
import PDFKit
import UniformTypeIdentifiers
import AppKit
import Vision
import CoreGraphics

class DocumentProcessor: BaseConverter, MediaConverting {
    private let imageProcessor: ImageProcessor
    
    override init(settings: ConversionSettings = ConversionSettings()) {
        self.imageProcessor = ImageProcessor(settings: settings)
        super.init(settings: settings)
    }
    
    func validateConversion(from inputType: UTType, to outputType: UTType) throws -> ConversionStrategy {
        guard canConvert(from: inputType, to: outputType) else {
            throw ConversionError.incompatibleFormats
        }
        
        if inputType == .pdf && outputType.conforms(to: .image) {
            return .extractFrame
        } else if inputType.conforms(to: .image) && outputType == .pdf {
            return .createVideo
        }
        
        throw ConversionError.incompatibleFormats
    }
    
    func canConvert(from: UTType, to: UTType) -> Bool {
        // Support PDF to image/video conversions
        if from == .pdf {
            return to.conforms(to: .image) || to.conforms(to: .audiovisualContent)
        }
        
        // Support image/video to PDF
        if to == .pdf {
            return from.conforms(to: .image) || from.conforms(to: .audiovisualContent)
        }
        
        return false
    }
    
    func convert(_ url: URL, to outputFormat: UTType, progress: Progress) async throws -> ProcessingResult {
        let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey])
        guard let inputType = resourceValues.contentType else {
            throw ConversionError.invalidInput
        }
        
        let outputURL = try CacheManager.shared.createTemporaryURL(for: url.lastPathComponent)
        
        switch (inputType, outputFormat) {
        case (.pdf, _) where outputFormat.conforms(to: .image):
            return try await convertPDFToImage(url, outputFormat: outputFormat, outputURL: outputURL, progress: progress)
            
        case (_, .pdf) where inputType.conforms(to: .image):
            return try await convertImageToPDF(url, outputURL: outputURL, progress: progress)
            
        default:
            throw ConversionError.incompatibleFormats
        }
    }
    
    private func convertPDFToImage(_ url: URL, outputFormat: UTType, outputURL: URL, progress: Progress) async throws -> ProcessingResult {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.documentConversionFailed
        }
        
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ConversionError.invalidInput
        }
        
        // For single page PDFs
        if pageCount == 1 {
            guard let page = document.page(at: 0) else {
                throw ConversionError.documentConversionFailed
            }
            
            let image = await renderPDFPage(page)
            try await imageProcessor.saveImage(image, format: outputFormat, to: outputURL)
            
            progress.completedUnitCount = 100
            
            return ProcessingResult(
                outputURL: outputURL,
                originalFileName: url.lastPathComponent,
                suggestedFileName: url.deletingPathExtension().lastPathComponent + "." + (outputFormat.preferredFilenameExtension ?? "jpg"),
                fileType: outputFormat
            )
        }
        
        // For multi-page PDFs, create a directory with numbered images
        let baseURL = outputURL.deletingLastPathComponent()
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        
        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            let pageImage = await renderPDFPage(page)
            let pageURL = baseURL.appendingPathComponent("\(baseName)_page\(pageIndex + 1).\(outputFormat.preferredFilenameExtension ?? "jpg")")
            
            try await imageProcessor.saveImage(pageImage, format: outputFormat, to: pageURL)
            
            progress.completedUnitCount = Int64((Double(pageIndex + 1) / Double(pageCount)) * 100)
        }
        
        return ProcessingResult(
            outputURL: baseURL,
            originalFileName: url.lastPathComponent,
            suggestedFileName: baseName,
            fileType: outputFormat
        )
    }
    
    private func convertImageToPDF(_ url: URL, outputURL: URL, progress: Progress) async throws -> ProcessingResult {
        guard let image = NSImage(contentsOf: url) else {
            throw ConversionError.invalidInput
        }
        
        let pdfDocument = PDFDocument()
        
        // Create PDF page from image
        _ = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let pdfPage = PDFPage(image: image) else {
            throw ConversionError.conversionFailed
        }
        
        pdfDocument.insert(pdfPage, at: 0)
        
        guard pdfDocument.write(to: outputURL) else {
            throw ConversionError.exportFailed
        }
        
        progress.completedUnitCount = 100
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: url.lastPathComponent,
            suggestedFileName: url.deletingPathExtension().lastPathComponent + ".pdf",
            fileType: .pdf
        )
    }
    
    private func renderPDFPage(_ page: PDFPage) async -> NSImage {
        let pageRect = page.bounds(for: .mediaBox)
        let renderer = NSImage(size: pageRect.size)
        
        renderer.lockFocus()
        if let context = NSGraphicsContext.current {
            context.imageInterpolation = .high
            context.shouldAntialias = true
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        renderer.unlockFocus()
        
        return renderer
    }
}
