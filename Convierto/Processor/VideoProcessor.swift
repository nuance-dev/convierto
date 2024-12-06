import AVFoundation
import UniformTypeIdentifiers
import CoreImage
import AppKit
import os

protocol ResourceManaging {
    func cleanup()
}

class VideoProcessor: BaseConverter {
    private weak var processorFactory: ProcessorFactory?
    private let audioVisualizer: AudioVisualizer
    private let imageProcessor: ImageProcessor
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "VideoProcessor")
    
    required init(settings: ConversionSettings = ConversionSettings()) {
        self.audioVisualizer = AudioVisualizer(size: CGSize(width: 1920, height: 1080))
        self.imageProcessor = ImageProcessor(settings: settings)
        super.init(settings: settings)
    }
    
    convenience init(settings: ConversionSettings = ConversionSettings(), factory: ProcessorFactory? = nil) {
        self.init(settings: settings)
        self.processorFactory = factory
    }
    
    override func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        logger.debug("🎬 Starting video conversion")
        let urlPath = url.path(percentEncoded: false)
        logger.debug("📂 Input URL: \(urlPath)")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        let asset = AVURLAsset(url: url)
        logger.debug("✅ Created AVURLAsset")
        
        do {
            logger.debug("⚙️ Attempting primary conversion")
            return try await performConversion(asset: asset, originalURL: url, to: format, metadata: metadata, progress: progress)
        } catch {
            logger.error("❌ Primary conversion failed: \(error.localizedDescription)")
            logger.debug("🔄 Attempting fallback conversion")
            return try await handleFallback(asset: asset, originalURL: url, to: format, metadata: metadata, progress: progress)
        }
    }
    
    override func canConvert(from: UTType, to: UTType) -> Bool {
        switch (from, to) {
        case (let f, _) where f.conforms(to: .audiovisualContent):
            return true
        case (_, let t) where t.conforms(to: .audiovisualContent):
            return true
        default:
            return false
        }
    }
    
    private func handleFallback(
        asset: AVAsset,
        originalURL: URL,
        to format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        if format.conforms(to: .image) {
            return try await extractKeyFrame(from: asset, format: format, metadata: metadata)
        }
        
        // Try with reduced quality settings
        let fallbackSettings = ConversionSettings(
            videoQuality: AVAssetExportPresetMediumQuality,
            videoBitRate: 1_000_000,
            audioBitRate: 64_000,
            frameRate: 24
        )
        
        return try await performConversion(
            asset: asset,
            originalURL: originalURL,
            to: format,
            metadata: metadata,
            progress: progress,
            settings: fallbackSettings
        )
    }
    
    private func performConversion(
        asset: AVAsset,
        originalURL: URL,
        to format: UTType,
        metadata: ConversionMetadata,
        progress: Progress,
        settings: ConversionSettings = ConversionSettings()
    ) async throws -> ProcessingResult {
        logger.debug("⚙️ Starting conversion process")
        
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
        let outputPath = outputURL.path(percentEncoded: false)
        logger.debug("📂 Created temporary output URL: \(outputPath)")
        
        guard let exportSession = try await createExportSession(for: asset, outputFormat: format) else {
            logger.error("❌ Failed to create export session")
            throw ConversionError.conversionFailed(reason: "Failed to create export session")
        }
        logger.debug("✅ Created export session")
        
        // Make exportSession Sendable by isolating it
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    exportSession.outputURL = outputURL
                    exportSession.outputFileType = getAVFileType(for: format)
                    logger.debug("⚙️ Configured export session with type: \(String(describing: exportSession.outputFileType?.rawValue))")
                    
                    if let audioMix = try await createAudioMix(for: asset) {
                        exportSession.audioMix = audioMix
                        logger.debug("🎵 Applied audio mix")
                    }
                    
                    if format.conforms(to: .audiovisualContent) {
                        let videoComposition = try await createVideoComposition(for: asset)
                        exportSession.videoComposition = videoComposition
                        logger.debug("🎥 Applied video composition")
                    }
                    
                    logger.debug("▶️ Starting export")
                    
                    // Create progress tracking task
                    let progressTask = Task {
                        while !Task.isCancelled {
                            let currentProgress = exportSession.progress
                            progress.completedUnitCount = Int64(currentProgress * 100)
                            logger.debug("📊 Export progress: \(Int(currentProgress * 100))%")
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            if exportSession.status == .completed || exportSession.status == .failed {
                                break
                            }
                        }
                    }
                    
                    // Start export
                    await exportSession.export()
                    progressTask.cancel()
                    
                    if exportSession.status == .completed {
                        logger.debug("✅ Export completed successfully")
                        let result = ProcessingResult(
                            outputURL: outputURL,
                            originalFileName: metadata.originalFileName ?? originalURL.lastPathComponent,
                            suggestedFileName: "converted_video." + (format.preferredFilenameExtension ?? "mp4"),
                            fileType: format,
                            metadata: try await extractMetadata(from: asset)
                        )
                        continuation.resume(returning: result)
                    } else if let error = exportSession.error {
                        logger.error("❌ Export failed: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: ConversionError.conversionFailed(reason: "Export failed"))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func extractKeyFrame(from asset: AVAsset, format: UTType, metadata: ConversionMetadata) async throws -> ProcessingResult {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        let imageRef = try await generator.image(at: time).image
        
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "jpg")
        let nsImage = NSImage(cgImage: imageRef, size: NSSize(width: imageRef.width, height: imageRef.height))
        
        let imageProcessor = ImageProcessor()
        try await imageProcessor.saveImage(
            nsImage,
            format: format,
            to: outputURL,
            metadata: metadata
        )
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "frame",
            suggestedFileName: "extracted_frame." + (format.preferredFilenameExtension ?? "jpg"),
            fileType: format,
            metadata: nil
        )
    }
    
    private func createSimpleAnimation(for asset: AVAsset, format: UTType, metadata: ConversionMetadata) async throws -> ProcessingResult {
        // Implementation for creating simple animation
        // This would be called as a fallback when regular conversion fails
        logger.debug("Creating simple animation fallback")
        
        // Extract a frame and create a simple animation from it
        let frame = try await extractKeyFrame(from: asset, format: .jpeg, metadata: metadata)
        guard let image = NSImage(contentsOf: frame.outputURL) else {
            throw ConversionError.conversionFailed(reason: "Failed to load frame image")
        }
        
        return try await imageProcessor.createVideoFromImage(image, format: format, metadata: metadata, progress: Progress())
    }
    
    private func createVideoComposition(for asset: AVAsset) async throws -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.conversionFailed(reason: "No video track found")
        }
        
        let trackSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        
        let targetSize = settings.maintainAspectRatio ? 
            calculateAspectFitSize(trackSize, target: settings.targetSize) :
            settings.targetSize
        
        composition.renderSize = targetSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        composition.renderScale = 1.0
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        
        if settings.brightness != 0.0 {
            layerInstruction.setOpacity(Float(settings.brightness), at: .zero)
        }
        
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        
        return composition
    }
    
    private func calculateAspectFitSize(_ originalSize: CGSize, target: CGSize) -> CGSize {
        let widthRatio = target.width / originalSize.width
        let heightRatio = target.height / originalSize.height
        let scale = min(widthRatio, heightRatio)
        
        return CGSize(
            width: originalSize.width * scale,
            height: originalSize.height * scale
        )
    }
    
    private func extractMetadata(from asset: AVAsset) async throws -> [String: Any] {
        var metadata: [String: Any] = [:]
        
        metadata["duration"] = try await asset.load(.duration).seconds
        metadata["preferredRate"] = try await asset.load(.preferredRate)
        metadata["preferredVolume"] = try await asset.load(.preferredVolume)
        
        if let format = try await asset.load(.availableMetadataFormats).first {
            let items = try await asset.loadMetadata(for: format)
            for item in items {
                if let key = item.commonKey?.rawValue,
                   let value = try? await item.load(.value) {
                    metadata[key] = value
                }
            }
        }
        
        return metadata
    }
    
    private func createVideoFromImage(_ image: NSImage, format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        logger.debug("🎬 Creating video from image")
        
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
        logger.debug("📝 Output URL created: \(outputURL.path)")
        
        let videoWriter = try AVAssetWriter(url: outputURL, fileType: .mp4)
        logger.debug("✅ Created AVAssetWriter")
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(image.size.width),
            AVVideoHeightKey: Int(image.size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        logger.debug("⚙️ Video settings configured: \(videoSettings)")
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        logger.debug("✅ Video input configured")
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(image.size.width),
                kCVPixelBufferHeightKey as String: Int(image.size.height)
            ]
        )
        logger.debug("✅ Pixel buffer adaptor configured")
        
        videoWriter.add(videoInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        logger.debug("🎬 Started writing session")
        
        // Create a 3-second video
        let frameDuration = CMTimeMake(value: 1, timescale: 30)
        let frameCount = 90 // 3 seconds at 30fps
        logger.debug("⚙️ Configured for \(frameCount) frames at \(30)fps")
        
        for frameIndex in 0..<frameCount {
            if let buffer = try await createPixelBuffer(from: image) {
                logger.debug("✅ Pixel buffer created successfully")
                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                adaptor.append(buffer, withPresentationTime: presentationTime)
                logger.debug("📝 Writing video frame \(frameIndex + 1)/\(frameCount)")
            }
        }
        
        videoInput.markAsFinished()
        await videoWriter.finishWriting()
        logger.debug("✅ Video writing completed")
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "image",
            suggestedFileName: "converted_video.mp4",
            fileType: format,
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
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            logger.error("❌ Failed to create pixel buffer")
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
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            logger.error("❌ Failed to create CGContext")
            return nil
        }
        
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        
        return buffer
    }
}
