import CoreGraphics
import UniformTypeIdentifiers
import AppKit
import ImageIO
import CoreImage
import AVFoundation
import os.log

// Image Processor Implementation
class ImageProcessor: BaseConverter {
    private let ciContext: CIContext
    private let contextId: String
    private weak var processorFactory: ProcessorFactory?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
        category: "ImageProcessor"
    )
    
    required init(settings: ConversionSettings = ConversionSettings()) {
        self.contextId = UUID().uuidString
        self.ciContext = GraphicsContextManager.shared.context(for: contextId)
        self.processorFactory = nil
        super.init(settings: settings)
    }
    
    convenience init(settings: ConversionSettings = ConversionSettings(), factory: ProcessorFactory? = nil) {
        self.init(settings: settings)
        self.processorFactory = factory
    }
    
    deinit {
        GraphicsContextManager.shared.releaseContext(for: contextId)
    }
    
    override func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        logger.debug("🔄 Starting image conversion with detailed debugging")
        logger.debug("📍 Source URL: \(url.path)")
        logger.debug("🎯 Target format: \(format.identifier)")
        logger.debug("⚙️ Quality setting: \(self.settings.imageQuality)")
        
        // Validate input
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            logger.error("❌ Failed to create image source from URL")
            logger.debug("🔍 URL validation failed - Path: \(url.path)")
            throw ConversionError.invalidInput
        }
        
        // Get source properties for debugging
        if let properties = CGImageSourceCopyProperties(imageSource, nil) as? [CFString: Any] {
            logger.debug("📊 Source image properties: \(properties)")
        }
        
        // Get source format
        guard let sourceUTI = CGImageSourceGetType(imageSource) as String?,
              let sourceType = UTType(sourceUTI) else {
            logger.error("❌ Failed to determine source image type")
            logger.debug("🔍 Source UTI: ")
            throw ConversionError.invalidInput
        }
        
        logger.debug("📄 Source type: \(sourceType.identifier)")
        
        // Create output URL
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "jpg")
        logger.debug("📂 Output URL: \(outputURL.path)")
        
        // Configure destination options with detailed logging
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: settings.imageQuality,
            kCGImageDestinationOptimizeColorForSharing: true
        ]
        logger.debug("⚙️ Destination options: \(destinationOptions)")
        
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            format.identifier as CFString,
            1,
            nil
        ) else {
            logger.error("❌ Failed to create image destination")
            logger.debug("💾 Destination creation failed for URL: \(outputURL.path)")
            throw ConversionError.exportFailed(reason: "Failed to create image destination")
        }
        
        do {
            if let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                logger.debug("✅ CGImage created successfully")
                logger.debug("📐 Image dimensions: \(cgImage.width)x\(cgImage.height)")
                logger.debug("🎨 Color space: \(cgImage.colorSpace?.name ?? "unknown" as CFString)")
                logger.debug("⚡️ Bits per component: \(cgImage.bitsPerComponent)")
                logger.debug("🔢 Bits per pixel: \(cgImage.bitsPerPixel)")
                
                // Add image to destination with detailed error handling
                CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
                
                if CGImageDestinationFinalize(destination) {
                    logger.debug("✅ Image conversion successful")
                    logger.debug("📦 Output file size: x bytes")
                    
                    return ProcessingResult(
                        outputURL: outputURL,
                        originalFileName: metadata.originalFileName ?? "image",
                        suggestedFileName: "converted_image." + (format.preferredFilenameExtension ?? "jpg"),
                        fileType: format,
                        metadata: nil
                    )
                } else {
                    logger.error("❌ Failed to finalize image destination")
                    logger.debug("💾 Finalization failed for URL: \(outputURL.path)")
                    throw ConversionError.exportFailed(reason: "Failed to write image to disk")
                }
            } else {
                logger.error("❌ Failed to create CGImage from source")
                logger.debug("🔍 Source image creation failed")
                throw ConversionError.conversionFailed(reason: "Failed to process image data")
            }
        } catch {
            logger.error("❌ Conversion failed with error: \(error.localizedDescription)")
            logger.debug("⚠️ Error details: \(error)")
            throw error
        }
    }
    
    private func handleVideoConversion(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        guard let factory = processorFactory else {
            throw ConversionError.conversionFailed(reason: "Processor factory not available")
        }
        
        let videoProcessor = factory.processor(for: .mpeg4Movie) as? VideoProcessor
        guard let processor = videoProcessor else {
            throw ConversionError.conversionFailed(reason: "Video processor not available")
        }
        
        do {
            return try await processor.convert(url, to: format, metadata: metadata, progress: progress)
        } catch {
            if let image = NSImage(contentsOf: url) {
                return try await createVideoFromImage(image, format: format, metadata: metadata, progress: progress)
            }
            throw error
        }
    }
    
    private func handleImageConversion(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        // Load image data
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.invalidInput
        }
        
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "jpg")
        
        // Create destination with proper type identifier
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            format.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.exportFailed(reason: "Failed to create image destination")
        }
        
        // Configure destination options
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: settings.imageQuality,
            kCGImageDestinationOptimizeColorForSharing: true
        ]
        
        // Copy source image with options
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) {
            CGImageDestinationAddImageFromSource(
                destination,
                imageSource,
                0,
                properties as CFDictionary
            )
        } else {
            // Fallback if properties cannot be copied
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw ConversionError.conversionFailed(reason: "Failed to create image")
            }
            CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
        }
        
        // Finalize the destination
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.exportFailed(reason: "Failed to write image to disk")
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "image",
            suggestedFileName: "converted_image." + (format.preferredFilenameExtension ?? "jpg"),
            fileType: format,
            metadata: nil
        )
    }
    
    func createVideoFromImage(_ image: NSImage, format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
        
        let videoWriter = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(image.size.width),
            AVVideoHeightKey: Int(image.size.height)
        ]
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )
        
        videoWriter.add(videoInput)
        
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        
        if let buffer = try await createPixelBuffer(from: image) {
            adaptor.append(buffer, withPresentationTime: .zero)
        }
        
        videoInput.markAsFinished()
        await videoWriter.finishWriting()
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "image_to_video",
            suggestedFileName: "converted_video." + (format.preferredFilenameExtension ?? "mp4"),
            fileType: format,
            metadata: nil
        )
    }
    
    private func processImage(
        imageSource: CGImageSource,
        outputFormat: UTType,
        metadata: ConversionMetadata,
        progress: Progress,
        inputURL: URL,
        outputURL: URL,
        settings: ConversionSettings = ConversionSettings()
    ) async throws -> ProcessingResult {
        
        // Configure conversion options
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true
        ]
        
        progress.completedUnitCount = 30
        
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
            throw ConversionError.conversionFailed(reason: "Failed to create image")
        }
        
        progress.completedUnitCount = 50
        
        // Create destination
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            outputFormat.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.exportFailed(reason: "Failed to create image destination")
        }
        
        progress.completedUnitCount = 70
        
        // Configure destination options
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: settings.imageQuality,
            kCGImageDestinationOptimizeColorForSharing: true
        ]
        
        // Add image to destination
        CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
        
        progress.completedUnitCount = 90
        
        // Finalize
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.exportFailed(reason: "Failed to write image to disk")
        }
        
        progress.completedUnitCount = 100
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "image",
            suggestedFileName: "converted_image." + (outputFormat.preferredFilenameExtension ?? "jpg"),
            fileType: outputFormat,
            metadata: nil
        )
    }
    
    private func applyImageProcessing(_ image: CGImage) async throws -> CGImage {
        // Create a new CIContext for each processing operation
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .allowLowPower: true
        ])
        
        let ciImage = CIImage(cgImage: image)
        var processedImage = ciImage
        
        // Use autoreleasepool to manage memory during processing
        return try await autoreleasepool {
            if settings.enhanceImage {
                if let filter = CIFilter(name: "CIPhotoEffectInstant") {
                    filter.setValue(processedImage, forKey: kCIInputImageKey)
                    if let output = filter.outputImage {
                        processedImage = output
                    }
                }
            }
            
            if settings.adjustColors {
                if let filter = CIFilter(name: "CIColorControls") {
                    filter.setValue(processedImage, forKey: kCIInputImageKey)
                    filter.setValue(settings.saturation, forKey: kCIInputSaturationKey)
                    filter.setValue(settings.brightness, forKey: kCIInputBrightnessKey)
                    filter.setValue(settings.contrast, forKey: kCIInputContrastKey)
                    if let output = filter.outputImage {
                        processedImage = output
                    }
                }
            }
            
            guard let cgImage = context.createCGImage(processedImage, from: processedImage.extent) else {
                throw ConversionError.conversionFailed(reason: "Failed to process image")
            }
            
            return cgImage
        }
    }
    
    private func insertFrame(
        _ image: CGImage,
        at time: CMTime,
        duration: CMTime,
        into track: AVMutableCompositionTrack
    ) async throws {
        let imageSize = CGSize(width: image.width, height: image.height)
        
        // Create video frame
        let frameImage = NSImage(cgImage: image, size: imageSize)
        guard let frameData = frameImage.tiffRepresentation else {
            throw ConversionError.conversionFailed(reason: "Failed to create frame data")
        }
        
        // Create temporary file for frame
        let frameURL = try CacheManager.shared.createTemporaryURL(for: "frame.tiff")
        try frameData.write(to: frameURL)
        
        // Create asset from frame
        let frameAsset = AVAsset(url: frameURL)
        if let videoTrack = try? await frameAsset.loadTracks(withMediaType: .video).first {
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: time
            )
        }
        
        try? FileManager.default.removeItem(at: frameURL)
    }
    
    func saveImage(_ image: NSImage, format: UTType, to url: URL, metadata: ConversionMetadata) async throws {
        guard let imageRep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
            throw ConversionError.conversionFailed(reason: "Failed to create image representation")
        }
        
        let properties: [NSBitmapImageRep.PropertyKey: Any] = [
            .compressionFactor: settings.imageQuality
        ]
        
        let imageData: Data?
        switch format {
        case .jpeg:
            imageData = imageRep.representation(using: .jpeg, properties: properties)
        case .png:
            imageData = imageRep.representation(using: .png, properties: [:])
        case .tiff:
            imageData = imageRep.representation(using: .tiff, properties: [:])
        default:
            throw ConversionError.unsupportedFormat(format: format)
        }
        
        guard let data = imageData else {
            throw ConversionError.conversionFailed(reason: "Failed to create image data")
        }
        
        try data.write(to: url)
    }
    
    func createVideoFromImageSequence(_ images: [NSImage], outputFormat: UTType) async throws -> ProcessingResult {
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: outputFormat.preferredFilenameExtension ?? "mp4")
        
        guard let firstImage = images.first else {
            throw ConversionError.invalidInput
        }
        
        let videoWriter = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(firstImage.size.width),
            AVVideoHeightKey: Int(firstImage.size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10000000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )
        
        videoWriter.add(videoInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        
        for (index, image) in images.enumerated() {
            if let buffer = try await createPixelBuffer(from: image) {
                let presentationTime = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.frameRate))
                adaptor.append(buffer, withPresentationTime: presentationTime)
            }
        }
        
        videoInput.markAsFinished()
        await videoWriter.finishWriting()
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "image_sequence",
            suggestedFileName: "converted_video." + (outputFormat.preferredFilenameExtension ?? "mp4"),
            fileType: outputFormat,
            metadata: nil
        )
    }
    
    private func createPixelBuffer(from image: NSImage) async throws -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        
        guard let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        
        return buffer
    }
    
    override func validateConversion(from inputType: UTType, to outputType: UTType) throws -> ConversionStrategy {
        logger.debug("Validating conversion from \(inputType.identifier) to \(outputType.identifier)")
        
        guard canConvert(from: inputType, to: outputType) else {
            logger.error("Incompatible formats detected")
            throw ConversionError.incompatibleFormats(from: inputType, to: outputType)
        }
        
        if inputType.conforms(to: .image) && outputType.conforms(to: .image) {
            logger.debug("Using direct conversion strategy for image to image")
            return .direct
        }
        
        if inputType.conforms(to: .image) && outputType.conforms(to: .audiovisualContent) {
            logger.debug("Using createVideo strategy for image to video")
            return .createVideo
        }
        
        logger.error("No valid conversion strategy found")
        throw ConversionError.conversionNotPossible(reason: "No valid conversion strategy")
    }
    
    override func canConvert(from: UTType, to: UTType) -> Bool {
        logger.debug("⚙️ Checking conversion compatibility: \(from.identifier) -> \(to.identifier)")
        
        // Allow conversion between any image formats
        if from.conforms(to: .image) && to.conforms(to: .image) {
            logger.debug("✅ Compatible image formats detected")
            return true
        }
        
        logger.debug("❌ Incompatible formats")
        return false
    }
    
    func processImage(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        logger.debug("🔄 Starting image conversion with detailed debugging")
        
        // Create image source
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.invalidInput
        }
        
        // Create output URL
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "jpg")
        
        // Configure destination options
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: settings.imageQuality,
            kCGImageDestinationOptimizeColorForSharing: true
        ]
        
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            format.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.exportFailed(reason: "Failed to create image destination")
        }
        
        // Perform conversion
        if let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
            CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
            
            if CGImageDestinationFinalize(destination) {
                return ProcessingResult(
                    outputURL: outputURL,
                    originalFileName: metadata.originalFileName ?? "image",
                    suggestedFileName: "converted_image." + (format.preferredFilenameExtension ?? "jpg"),
                    fileType: format,
                    metadata: nil
                )
            }
        }
        
        throw ConversionError.conversionFailed(reason: "Failed to process image")
    }
}
