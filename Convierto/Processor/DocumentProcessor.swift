import Foundation
import PDFKit
import UniformTypeIdentifiers
import AppKit
import Vision
import CoreGraphics
import os.log

class DocumentProcessor: BaseConverter {
    private let imageProcessor: ImageProcessor
    private let resourcePool: ResourcePool
    private let maxPageBufferSize: UInt64 = 100 * 1024 * 1024 // 100MB per page
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "DocumentProcessor")
    
    required init(settings: ConversionSettings = ConversionSettings()) {
        self.resourcePool = ResourcePool.shared
        self.imageProcessor = ImageProcessor(settings: settings)
        super.init(settings: settings)
    }
    
    override func canConvert(from: UTType, to: UTType) -> Bool {
        switch (from, to) {
        case (.pdf, let t) where t.conforms(to: .image):
            return true
        case (let f, .pdf) where f.conforms(to: .image):
            return true
        case (.pdf, let t) where t.conforms(to: .audiovisualContent):
            return true
        default:
            return false
        }
    }
    
    override func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        logger.debug("📄 Starting document conversion process")
        logger.debug("📂 Input file: \(url.path)")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        let taskId = UUID()
        logger.debug("🔑 Task ID: \(taskId.uuidString)")
        
        await resourcePool.beginTask(id: taskId, type: .document)
        defer { Task { await resourcePool.endTask(id: taskId) } }
        
        do {
            let inputType = try await determineInputType(url)
            logger.debug("📋 Input type determined: \(inputType.identifier)")
            
            let strategy = try validateConversion(from: inputType, to: format)
            logger.debug("⚙️ Conversion strategy: \(String(describing: strategy))")
            
            try await resourcePool.checkResourceAvailability(taskId: taskId, type: .document)
            logger.debug("✅ Resource availability confirmed")
            
            return try await withTimeout(seconds: 180) {
                self.logger.debug("⏳ Starting conversion with 180s timeout")
                switch strategy {
                case .extractFrame:
                    self.logger.debug("🖼️ Converting PDF to image")
                    return try await self.convertPDFToImage(url, outputFormat: format, metadata: metadata, progress: progress)
                case .createVideo:
                    self.logger.debug("🎬 Converting PDF to video")
                    return try await self.convertPDFToVideo(url, outputFormat: format, metadata: metadata, progress: progress)
                case .combine:
                    self.logger.debug("📑 Converting image to PDF")
                    return try await self.convertImageToPDF(url, metadata: metadata, progress: progress)
                default:
                    self.logger.error("❌ Unsupported conversion strategy")
                    throw ConversionError.incompatibleFormats(from: inputType, to: format)
                }
            }
        } catch let error as ConversionError {
            logger.error("❌ Document conversion failed: \(error.localizedDescription)")
            throw error
        } catch {
            logger.error("❌ Unexpected error: \(error.localizedDescription)")
            throw ConversionError.conversionFailed(reason: error.localizedDescription)
        }
    }
    
    private func determineInputType(_ url: URL) async throws -> UTType {
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
        guard let contentType = resourceValues.contentType else {
            throw ConversionError.invalidInputType
        }
        return contentType
    }
    
    private func convertPDFToImage(_ url: URL, outputFormat: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.documentProcessingFailed(reason: "Could not open PDF document")
        }
        
        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ConversionError.invalidInput
        }
        
        // Configure conversion options
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true
        ]
        
        try await resourcePool.checkMemoryAvailability(required: maxPageBufferSize * UInt64(pageCount))
        
        if pageCount == 1 {
            return try await convertSinglePage(document.page(at: 0), format: outputFormat, metadata: metadata, progress: progress, options: options)
        } else {
            return try await convertMultiplePages(document, format: outputFormat, metadata: metadata, progress: progress, options: options)
        }
    }
    
    private func convertSinglePage(_ page: PDFPage?, format: UTType, metadata: ConversionMetadata, progress: Progress, options: [CFString: Any]) async throws -> ProcessingResult {
        guard let page = page else {
            throw ConversionError.documentProcessingFailed(reason: "Invalid PDF page")
        }
        
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "jpg")
        let image = await renderPDFPage(page)
        
        try await imageProcessor.saveImage(image, format: format, to: outputURL, metadata: metadata)
        progress.completedUnitCount = 100
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "document",
            suggestedFileName: "converted_page." + (format.preferredFilenameExtension ?? "jpg"),
            fileType: format,
            metadata: nil
        )
    }
    
    private func convertMultiplePages(_ document: PDFDocument, format: UTType, metadata: ConversionMetadata, progress: Progress, options: [CFString: Any]) async throws -> ProcessingResult {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let outputDir = try tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        progress.totalUnitCount = Int64(document.pageCount)
        var convertedFiles: [URL] = []
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            let pageURL = outputDir.appendingPathComponent("page_\(pageIndex + 1).\(format.preferredFilenameExtension ?? "jpg")")
            let image = await renderPDFPage(page)
            
            try await imageProcessor.saveImage(image, format: format, to: pageURL, metadata: metadata)
            convertedFiles.append(pageURL)
            
            progress.completedUnitCount = Int64(pageIndex + 1)
        }
        
        return ProcessingResult(
            outputURL: outputDir,
            originalFileName: metadata.originalFileName ?? "document",
            suggestedFileName: "converted_pages",
            fileType: format,
            metadata: nil
        )
    }
    
    private func renderPDFPage(_ page: PDFPage) async -> NSImage {
        await withCheckedContinuation { continuation in
            autoreleasepool {
                let pageRect = page.bounds(for: .mediaBox)
                let renderer = NSImage(size: pageRect.size)
                
                renderer.lockFocus()
                if let context = NSGraphicsContext.current {
                    context.imageInterpolation = .high
                    context.shouldAntialias = true
                    page.draw(with: .mediaBox, to: context.cgContext)
                }
                renderer.unlockFocus()
                
                continuation.resume(returning: renderer)
            }
        }
    }
    
    private func convertPDFToVideo(_ url: URL, outputFormat: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        guard let document = PDFDocument(url: url) else {
            throw ConversionError.documentProcessingFailed(reason: "Could not open PDF document")
        }
        
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: outputFormat.preferredFilenameExtension ?? "mp4")
        
        // Implementation for PDF to video conversion
        // This is a placeholder - actual implementation would go here
        throw ConversionError.conversionFailed(reason: "PDF to video conversion not implemented")
    }
    
    private func convertImageToPDF(_ url: URL, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: "pdf")
        
        guard let image = NSImage(contentsOf: url) else {
            throw ConversionError.documentProcessingFailed(reason: "Could not load image")
        }
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.conversionFailed(reason: "Could not create CGImage")
        }
        
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        
        guard let pdfContext = CGContext(consumer: CGDataConsumer(data: pdfData)!,
                                       mediaBox: &mediaBox,
                                       nil) else {
            throw ConversionError.conversionFailed(reason: "Could not create PDF context")
        }
        
        pdfContext.beginPage(mediaBox: &mediaBox)
        pdfContext.draw(cgImage, in: mediaBox)
        pdfContext.endPage()
        pdfContext.closePDF()
        
        try pdfData.write(to: outputURL, options: .atomic)
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "image",
            suggestedFileName: "converted_document.pdf",
            fileType: .pdf,
            metadata: nil
        )
    }
}
