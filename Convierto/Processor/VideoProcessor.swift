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
        
        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    continuation.resume()
                } else if let error = exportSession.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: ConversionError.conversionFailed(reason: "Export failed"))
                }
            }
        }
        
        progressTask.cancel()
        logger.debug("⏹️ Export completed with status: \(exportSession.status.rawValue)")
        
        guard exportSession.status == .completed else {
            if let error = exportSession.error {
                logger.error("❌ Export failed: \(error.localizedDescription)")
            }
            throw exportSession.error ?? ConversionError.conversionFailed(reason: "Export failed")
        }
        
        logger.debug("✅ Conversion successful")
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? originalURL.lastPathComponent,
            suggestedFileName: "converted_video." + (format.preferredFilenameExtension ?? "mp4"),
            fileType: format,
            metadata: try await extractMetadata(from: asset)
        )
    }
    
    private func extractKeyFrame(from asset: AVAsset, format: UTType, metadata: ConversionMetadata) async throws -> ProcessingResult {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        let imageRef = try await generator.image(at: time).image
        
        let outputURL = try await CacheManager.shared.createTemporaryFile(withExtension: format.preferredFilenameExtension ?? "jpg")
        let nsImage = NSImage(cgImage: imageRef, size: NSSize(width: imageRef.width, height: imageRef.height))
        
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
    
    func createVideoFromImage(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        logger.debug("🎬 Starting image to video conversion")
        logger.debug("📂 Source image: \(url.path)")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        // Create temporary URL for output
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
        logger.debug("📝 Output URL created: \(outputURL.path)")
        
        // Load source image
        guard let image = NSImage(contentsOf: url) else {
            logger.error("❌ Failed to load source image")
            throw ConversionError.invalidInput
        }
        logger.debug("✅ Source image loaded successfully")
        
        // Create video settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: image.size.width,
            AVVideoHeightKey: image.size.height
        ]
        logger.debug("⚙️ Video settings configured: \(videoSettings)")
        
        // Create AVAssetWriter
        guard let assetWriter = try? AVAssetWriter(url: outputURL, fileType: .mp4) else {
            logger.error("❌ Failed to create asset writer")
            throw ConversionError.conversionFailed(reason: "Failed to create video writer")
        }
        
        // Add video input
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )
        
        assetWriter.add(videoInput)
        logger.debug("✅ Video input configured")
        
        // Start writing session
        assetWriter.startWriting()
        assetWriter.startSession(atSourceTime: .zero)
        logger.debug("🎬 Started writing session")
        
        // Create pixel buffer
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(image.size.width),
            Int(image.size.height),
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        
        if let pixelBuffer = pixelBuffer {
            logger.debug("✅ Pixel buffer created successfully")
            
            // Write frames
            let frameDuration = CMTimeMake(value: 1, timescale: 1)
            
            videoInput.requestMediaDataWhenReady(on: .main) {
                self.logger.debug("📝 Writing video frame")
                adaptor.append(pixelBuffer, withPresentationTime: .zero)
                videoInput.markAsFinished()
                
                assetWriter.finishWriting {
                    self.logger.debug("✅ Video writing completed")
                }
            }
            
            // Wait for completion
            while assetWriter.status == .writing {
                await Task.sleep(100_000_000) // 0.1 second
            }
            
            if assetWriter.status == .completed {
                logger.debug("🎉 Video creation successful")
                return ProcessingResult(
                    outputURL: outputURL,
                    originalFileName: metadata.originalFileName ?? "video",
                    suggestedFileName: "converted_video.mp4",
                    fileType: format,
                    metadata: nil
                )
            }
        }
        
        logger.error("❌ Failed to create video")
        throw ConversionError.conversionFailed(reason: "Failed to create video from image")
    }
}
