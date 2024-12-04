import CoreGraphics
import UniformTypeIdentifiers
import AppKit
import ImageIO
import CoreImage
import AVFoundation

// Image Processor Implementation
class ImageProcessor {
    private let settings: ConversionSettings
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    
    init(settings: ConversionSettings = ConversionSettings()) {
        self.settings = settings
    }
    
    func convert(_ inputURL: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        
        guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, sourceOptions as CFDictionary) else {
            throw ConversionError.invalidInput
        }
        
        // Special handling for different conversion types
        if format.conforms(to: .video) {
            return try await convertToVideo(imageSource: imageSource, format: format, progress: progress, inputURL: inputURL)
        } else if format.conforms(to: .gif) {
            return try await convertToAnimatedGIF(imageSource: imageSource, progress: progress, inputURL: inputURL)
        }
        
        // Regular image conversion with enhanced processing
        let result = try await processImage(
            imageSource: imageSource,
            outputFormat: format,
            progress: progress,
            inputURL: inputURL
        )
        
        progress.completedUnitCount = 100
        return result
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
        let ciImage = CIImage(cgImage: image)
        var processedImage = ciImage
        
        if settings.enhanceImage {
            if let filter = CIFilter(name: "CIPhotoEffectInstant") {
                filter.setValue(processedImage, forKey: kCIInputImageKey)
                processedImage = filter.outputImage ?? processedImage
            }
        }
        
        if settings.adjustColors {
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(processedImage, forKey: kCIInputImageKey)
                filter.setValue(settings.saturation, forKey: kCIInputSaturationKey)
                filter.setValue(settings.brightness, forKey: kCIInputBrightnessKey)
                filter.setValue(settings.contrast, forKey: kCIInputContrastKey)
                processedImage = filter.outputImage ?? processedImage
            }
        }
        
        guard let cgImage = ciContext.createCGImage(processedImage, from: processedImage.extent) else {
            throw ConversionError.conversionFailed
        }
        
        return cgImage
    }
    
    private func convertToVideo(imageSource: CGImageSource, format: UTType, progress: Progress, inputURL: URL) async throws -> ProcessingResult {
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError.conversionFailed
        }
        
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ConversionError.conversionFailed
        }
        
        let duration = CMTime(seconds: settings.videoDuration, preferredTimescale: 600)
        let size = CGSize(
            width: cgImage.width,
            height: cgImage.height
        )
        
        let frameCount = Int(duration.seconds * Double(settings.frameRate))
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        
        let animation = try await createImageAnimation(cgImage, frameCount: frameCount)
        
        for (index, frame) in animation.enumerated() {
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(settings.frameRate))
            try await insertFrame(frame, at: time, duration: frameDuration, into: videoTrack)
            progress.completedUnitCount = Int64((Double(index) / Double(frameCount)) * 50)
        }
        
        videoComposition.renderSize = size
        videoComposition.frameDuration = frameDuration
        
        let outputURL = try CacheManager.shared.createTemporaryURL(for: "video_output")
        
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: settings.videoQuality
        ) else {
            throw ConversionError.exportFailed
        }
        
        export.outputURL = outputURL
        export.outputFileType = format == .quickTimeMovie ? .mov : .mp4
        export.videoComposition = videoComposition
        
        await export.export()
        
        guard export.status == .completed else {
            throw export.error ?? ConversionError.exportFailed
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: inputURL.lastPathComponent,
            suggestedFileName: inputURL.deletingPathExtension().lastPathComponent + "." + (format.preferredFilenameExtension ?? "mp4"),
            fileType: format
        )
    }
    
    private func convertToAnimatedGIF(imageSource: CGImageSource, progress: Progress, inputURL: URL) async throws -> ProcessingResult {
        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ConversionError.conversionFailed
        }
        
        let frameCount = settings.gifFrameCount
        let animation = try await createImageAnimation(cgImage, frameCount: frameCount)
        
        let outputURL = try CacheManager.shared.createTemporaryURL(for: "animated.gif")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw ConversionError.exportFailed
        }
        
        // Configure GIF properties
        let gifProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
                kCGImagePropertyGIFHasGlobalColorMap: true,
                kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
                kCGImagePropertyDepth: 8
            ]
        ] as CFDictionary
        
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: settings.gifFrameDuration
            ]
        ] as CFDictionary
        
        CGImageDestinationSetProperties(destination, gifProperties)
        
        // Add frames to GIF
        for (index, frame) in animation.enumerated() {
            CGImageDestinationAddImage(destination, frame, frameProperties)
            progress.completedUnitCount = Int64((Double(index) / Double(frameCount)) * 100)
        }
        
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.exportFailed
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: inputURL.lastPathComponent,
            suggestedFileName: inputURL.deletingPathExtension().lastPathComponent + ".gif",
            fileType: .gif
        )
    }
    
    private func createImageAnimation(_ image: CGImage, frameCount: Int) async throws -> [CGImage] {
        var frames: [CGImage] = []
        let context = CIContext()
        
        // Fix CIImage initialization
        let ciImage = CIImage(cgImage: image)
        if ciImage == nil {
            throw ConversionError.conversionFailed
        }
        
        for i in 0..<frameCount {
            let progress = Double(i) / Double(frameCount)
            
            // Apply animation effects
            var animatedImage = ciImage
            
            if settings.animationStyle == .zoom {
                let scale = 1.0 + (0.2 * sin(progress * .pi * 2))
                animatedImage = animatedImage.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale)
                )
            } else if settings.animationStyle == .rotate {
                animatedImage = animatedImage.transformed(
                    by: CGAffineTransform(rotationAngle: progress * .pi * 2)
                )
            }
            
            // Convert back to CGImage
            guard let frameImage = context.createCGImage(
                animatedImage,
                from: animatedImage.extent
            ) else {
                throw ConversionError.conversionFailed
            }
            
            frames.append(frameImage)
        }
        
        return frames
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
        guard let imageRep = NSBitmapImageRep(data: image.tiffRepresentation!) else {
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
