import CoreGraphics
import UniformTypeIdentifiers
import AppKit
import ImageIO
import CoreImage
import AVFoundation

// Image Processor Implementation
class ImageProcessor: MediaConverting {
    let settings: ConversionSettings
    private let ciContext = CIContext()
    private let videoProcessor: VideoProcessor
    
    init(settings: ConversionSettings = ConversionSettings()) {
        self.settings = settings
        self.videoProcessor = VideoProcessor(settings: settings)
    }
    
    func canConvert(from: UTType, to: UTType) -> Bool {
        // Support image to image conversions
        if from.conforms(to: .image) && to.conforms(to: .image) {
            return true
        }
        
        // Support image to video conversions
        if from.conforms(to: .image) && to.conforms(to: .audiovisualContent) {
            return true
        }
        
        return false
    }
    
    func convert(_ inputURL: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
            throw ConversionError.invalidInput
        }
        
        // Special handling for different conversion types
        if format.conforms(to: .audiovisualContent) {
            guard let image = NSImage(contentsOf: inputURL) else {
                throw ConversionError.invalidInput
            }
            return try await createVideoFromImage(image, format: format, progress: progress)
        }
        
        // Process image with enhanced error handling
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError.conversionFailed
        }
        
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let outputURL = try CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "jpg")
        
        try await saveImage(nsImage, format: format, to: outputURL)
        
        progress.completedUnitCount = 100
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: inputURL.lastPathComponent,
            suggestedFileName: inputURL.deletingPathExtension().lastPathComponent + "." + (format.preferredFilenameExtension ?? "jpg"),
            fileType: format
        )
    }
    
    func createVideoFromImage(_ image: NSImage, format: UTType, progress: Progress) async throws -> ProcessingResult {
        let outputURL = try CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
        
        let videoWriter = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(image.size.width),
            AVVideoHeightKey: Int(image.size.height)
        ]
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)
            ]
        )
        
        videoWriter.add(videoInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        
        if let buffer = try await createPixelBuffer(from: image) {
            let frameDuration = CMTime(seconds: settings.videoDuration, preferredTimescale: 600)
            adaptor.append(buffer, withPresentationTime: .zero)
            try await Task.sleep(nanoseconds: UInt64(settings.videoDuration * 1_000_000_000))
        }
        
        videoInput.markAsFinished()
        await videoWriter.finishWriting()
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "image_to_video",
            suggestedFileName: "converted_video." + (format.preferredFilenameExtension ?? "mp4"),
            fileType: format
        )
    }
    
    private func processImage(
        imageSource: CGImageSource,
        outputFormat: UTType,
        progress: Progress,
        inputURL: URL
    ) async throws -> ProcessingResult {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let orientation = properties[kCGImagePropertyOrientation] as? Int32 else {
            throw ConversionError.conversionFailed
        }
        
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError.conversionFailed
        }
        
        // Apply image processing if needed
        let processedImage = try await applyImageProcessing(cgImage)
        
        // Create output URL
        let outputURL = try CacheManager.shared.createTemporaryURL(for: "processed_image")
        
        // Configure output options
        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: settings.imageQuality,
            kCGImageDestinationOptimizeColorForSharing: true,
            kCGImageDestinationOrientation: orientation
        ]
        
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            outputFormat.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.exportFailed
        }
        
        // Preserve metadata if needed
        if settings.preserveMetadata,
           let metadata = CGImageSourceCopyMetadataAtIndex(imageSource, 0, nil) {
            CGImageDestinationAddImageAndMetadata(
                destination,
                processedImage,
                metadata,
                destinationOptions as CFDictionary
            )
        } else {
            CGImageDestinationAddImage(destination, processedImage, destinationOptions as CFDictionary)
        }
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.exportFailed
        }
        
        let suggestedFileName = inputURL.deletingPathExtension().lastPathComponent + "." + 
            (outputFormat.preferredFilenameExtension ?? "img")
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: inputURL.lastPathComponent,
            suggestedFileName: suggestedFileName,
            fileType: outputFormat
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
                throw ConversionError.conversionFailed
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
            throw ConversionError.conversionFailed
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
    
    func saveImage(_ image: NSImage, format: UTType, to url: URL) async throws {
        guard let imageRep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()) else {
            throw ConversionError.conversionFailed
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
            throw ConversionError.unsupportedFormat
        }
        
        guard let data = imageData else {
            throw ConversionError.conversionFailed
        }
        
        try data.write(to: url)
    }
    
    func createVideoFromImageSequence(_ images: [NSImage], outputFormat: UTType) async throws -> ProcessingResult {
        let outputURL = try CacheManager.shared.createTemporaryURL(for: "video_output")
        
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
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(firstImage.size.width),
                kCVPixelBufferHeightKey as String: Int(firstImage.size.height)
            ]
        )
        
        videoWriter.add(videoInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        
        _ = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        
        for (index, image) in images.enumerated() {
            guard let pixelBuffer = try await createPixelBuffer(from: image) else {
                continue
            }
            
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10 * 1_000_000) // 10ms
            }
            
            let presentationTime = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.frameRate))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }
        
        videoInput.markAsFinished()
        await videoWriter.finishWriting()
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "image_sequence.mp4",
            suggestedFileName: "converted_video.mp4",
            fileType: outputFormat
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
}
