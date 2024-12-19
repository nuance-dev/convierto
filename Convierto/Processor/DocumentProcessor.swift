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
    
    required init(settings: ConversionSettings = ConversionSettings()) throws {
        self.resourcePool = ResourcePool.shared
        self.imageProcessor = try ImageProcessor(settings: settings)
        try super.init(settings: settings)
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
            
            switch strategy {
            case .extractFrame:
                logger.debug("🖼️ Converting PDF to image")
                return try await convertPDFToImage(url, outputFormat: format, metadata: metadata, progress: progress)
            case .combine:
                logger.debug("📑 Converting image to PDF")
                return try await convertImageToPDF(url, metadata: metadata, progress: progress)
            case .createVideo:
                logger.debug("🎬 Converting PDF to video")
                return try await convertPDFToVideo(url, outputFormat: format, metadata: metadata, progress: progress)
            default:
                logger.error("❌ Invalid conversion strategy")
                throw ConversionError.conversionFailed(reason: "Invalid conversion strategy")
            }
        } catch {
            logger.error("❌ Document conversion failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    private func determineInputType(_ url: URL) async throws -> UTType {
        let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey])
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
        
        try await resourcePool.checkMemoryAvailability(required: maxPageBufferSize * UInt64(pageCount))
        
        if pageCount == 1 {
            guard let page = document.page(at: 0) else {
                throw ConversionError.documentProcessingFailed(reason: "Invalid PDF page")
            }
            let image = renderPDFPage(page)
            let outputURL = try CacheManager.shared.createTemporaryURL(for: outputFormat.preferredFilenameExtension ?? "jpg")
            try await imageProcessor.saveImage(image, format: outputFormat, to: outputURL, metadata: metadata)
            progress.completedUnitCount = 100
            
            return ProcessingResult(
                outputURL: outputURL,
                originalFileName: metadata.originalFileName ?? "document",
                suggestedFileName: "converted_page." + (outputFormat.preferredFilenameExtension ?? "jpg"),
                fileType: outputFormat,
                metadata: nil
            )
        } else {
            return try await convertMultiplePages(document, format: outputFormat, metadata: metadata, progress: progress)
        }
    }
    
    private func convertSinglePage(
        _ page: PDFPage?,
        format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        guard let page = page else {
            throw ConversionError.documentProcessingFailed(reason: "Invalid PDF page")
        }
        
        let outputURL = try CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "jpg")
        let image = renderPDFPage(page)
        
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
    
    private func convertMultiplePages(
        _ document: PDFDocument,
        format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
        let outputDir = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        
        progress.totalUnitCount = Int64(document.pageCount)
        var convertedFiles: [URL] = []
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            let pageURL = outputDir.appendingPathComponent("page_\(pageIndex + 1).\(format.preferredFilenameExtension ?? "jpg")")
            let image = renderPDFPage(page)
            
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
    
    private func renderPDFPage(_ page: PDFPage) -> NSImage {
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
            
            return renderer
        }
    }
    
    private func convertPDFToVideo(_ url: URL, outputFormat: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        // For now, throw a more descriptive error
        throw ConversionError.featureNotImplemented(feature: "PDF to video conversion")
    }
    
    private func convertImageToPDF(_ url: URL, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        let outputURL = try CacheManager.shared.createTemporaryURL(for: "pdf")
        
        guard let image = NSImage(contentsOf: url) else {
            throw ConversionError.documentProcessingFailed(reason: "Could not load image")
        }
        
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        
        guard let context = CGContext(consumer: CGDataConsumer(data: pdfData)!,
                                    mediaBox: &mediaBox,
                                    nil) else {
            throw ConversionError.conversionFailed(reason: "Could not create PDF context")
        }
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.conversionFailed(reason: "Could not create CGImage")
        }
        
        context.beginPage(mediaBox: &mediaBox)
        context.draw(cgImage, in: mediaBox)
        context.endPage()
        context.closePDF()
        
        try pdfData.write(to: outputURL, options: .atomic)
        progress.completedUnitCount = 100
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "image",
            suggestedFileName: "converted_document.pdf",
            fileType: .pdf,
            metadata: nil
        )
    }
    
    override func validateConversion(from inputType: UTType, to outputType: UTType) throws -> ConversionStrategy {
        logger.debug("🔍 Validating conversion from \(inputType.identifier) to \(outputType.identifier)")
        
        switch (inputType, outputType) {
        case (.pdf, let t) where t.conforms(to: .image):
            return .extractFrame
        case (let f, .pdf) where f.conforms(to: .image):
            return .combine
        case (.pdf, let t) where t.conforms(to: .audiovisualContent):
            return .createVideo
        default:
            logger.error("❌ Unsupported conversion combination")
            throw ConversionError.incompatibleFormats(
                from: inputType,
                to: outputType,
                reason: "Unsupported conversion combination"
            )
        }
    }
}
