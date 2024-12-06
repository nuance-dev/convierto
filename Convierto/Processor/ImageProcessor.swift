import CoreGraphics
import UniformTypeIdentifiers
import AppKit
import ImageIO
import CoreImage
import AVFoundation

// Image Processor Implementation
class ImageProcessor: BaseConverter {
    private let ciContext: CIContext
    private let contextId: String
    private weak var processorFactory: ProcessorFactory?
    
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
        ResourceManager.shared.trackContext(contextId)
        
        if format.conforms(to: .audiovisualContent) {
            return try await handleVideoConversion(url, to: format, metadata: metadata, progress: progress)
        }
        
        return try await handleImageConversion(url, to: format, metadata: metadata, progress: progress)
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
        // Validate input format
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.invalidInput
        }
        
        // Create output URL with proper extension
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "jpg")
        
        // Configure conversion settings
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true
        ]
        
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, options as CFDictionary) else {
            throw ConversionError.conversionFailed(reason: "Failed to create image")
        }
        
        // Create NSImage from CGImage
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        
        // Save with proper format
        try await saveImage(nsImage, format: format, to: outputURL, metadata: metadata)
        
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
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            throw ConversionError.conversionFailed(reason: "Failed to read image properties")
        }
        
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError.conversionFailed(reason: "Failed to create image")
        }
        
        // Apply image processing
        let processedImage = try await applyImageProcessing(cgImage)
        
        // Configure output options
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: settings.imageQuality,
            kCGImageDestinationOptimizeColorForSharing: true
        ]
        
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            outputFormat.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.exportFailed(reason: "Failed to create image destination")
        }
        
        if settings.preserveMetadata,
           let imageMetadata = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil) {
            CGImageDestinationAddImageAndMetadata(
                destination,
                processedImage,
                imageMetadata,
                destinationOptions as CFDictionary
            )
        } else {
            CGImageDestinationAddImage(destination, processedImage, destinationOptions as CFDictionary)
        }
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.exportFailed(reason: "Failed to write image to disk")
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName,
            suggestedFileName: (metadata.originalFileName?.components(separatedBy: ".")[0] ?? "converted_image") + "." + (outputFormat.preferredFilenameExtension ?? "img"),
            fileType: outputFormat,
            metadata: properties
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
        guard canConvert(from: inputType, to: outputType) else {
            throw ConversionError.incompatibleFormats(from: inputType, to: outputType)
        }
        
        if inputType.conforms(to: .image) {
            if outputType.conforms(to: .audiovisualContent) {
                return .createVideo
            } else if outputType.conforms(to: .image) {
                return .direct
            }
        }
        
        throw ConversionError.incompatibleFormats(from: inputType, to: outputType)
    }
    
    override func canConvert(from: UTType, to: UTType) -> Bool {
        // Check if both types are images
        if from.conforms(to: .image) && to.conforms(to: .image) {
            // Explicitly support common image conversions
            let supportedFormats: Set<UTType> = [.jpeg, .png, .tiff, .gif, .heic]
            return supportedFormats.contains(from) || supportedFormats.contains(to)
        }
        return false
    }
}
