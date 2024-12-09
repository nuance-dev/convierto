import AVFoundation
import UniformTypeIdentifiers
import CoreImage
import AppKit
import os
import AudioToolbox

protocol ResourceManaging {
    func cleanup()
}

class VideoProcessor: BaseConverter {
    private weak var processorFactory: ProcessorFactory?
    private let audioVisualizer: AudioVisualizer
    private let imageProcessor: ImageProcessor
    private let coordinator: ConversionCoordinator
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "VideoProcessor")
    
    required init(settings: ConversionSettings = ConversionSettings()) throws {
        self.audioVisualizer = AudioVisualizer(size: CGSize(width: 1920, height: 1080))
        self.imageProcessor = try ImageProcessor(settings: settings)
        self.coordinator = ConversionCoordinator(settings: settings)
        try super.init(settings: settings)
    }
    
    convenience init(settings: ConversionSettings = ConversionSettings(), factory: ProcessorFactory? = nil) throws {
        try self.init(settings: settings)
        self.processorFactory = factory
    }
    
    override func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        let conversionId = UUID()
        logger.debug("🎬 Starting video conversion (ID: \(conversionId.uuidString))")
        
        await coordinator.trackConversion(conversionId)
        
        defer {
            Task {
                logger.debug("🏁 Completing video conversion (ID: \(conversionId.uuidString))")
                await coordinator.untrackConversion(conversionId)
            }
        }
        
        logger.debug("📂 Input URL: \(url.path(percentEncoded: false))")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        let asset = AVURLAsset(url: url)
        logger.debug("✅ Created AVURLAsset from provided URL")
        
        // Direct audio extraction for audio formats
        if format.conforms(to: .audio) || format == .mp3 {
            logger.debug("🎵 Using direct audio extraction")
            do {
                return try await extractAudio(from: asset, to: format, metadata: metadata, progress: progress)
            } catch {
                logger.error("❌ Audio extraction failed: \(error.localizedDescription)")
                // Try fallback with different settings
                return try await handleFallback(
                    asset: asset,
                    originalURL: url,
                    to: format,
                    metadata: metadata,
                    progress: progress
                )
            }
        }
        
        // Regular video conversion path
        return try await performConversion(
            asset: asset,
            originalURL: url,
            to: format,
            metadata: metadata,
            progress: progress
        )
    }
    
    override func canConvert(from: UTType, to: UTType) -> Bool {
        // Allow direct audio extraction from audiovisual content
        if to.conforms(to: .audio) || to == .mp3 {
            return from.conforms(to: .audiovisualContent) || from.conforms(to: .audio)
        }
        
        // General video conversions
        if from.conforms(to: .audiovisualContent) || to.conforms(to: .audiovisualContent) {
            return true
        }
        
        return false
    }
    
    private func handleFallback(
        asset: AVAsset,
        originalURL: URL,
        to format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        // If output is an image, try extracting a key frame
        if format.conforms(to: .image) {
            logger.debug("🎞 Fallback: Extracting key frame from video as image")
            return try await extractKeyFrame(from: asset, format: format, metadata: metadata)
        }
        
        // Otherwise, try with reduced quality settings
        let fallbackSettings = ConversionSettings(
            videoQuality: AVAssetExportPresetMediumQuality,
            videoBitRate: 1_000_000,
            audioBitRate: 64_000,
            frameRate: 24
        )
        
        logger.debug("🎞 Fallback: Retrying conversion with reduced quality")
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
        let duration = try await asset.load(.duration)
        
        logger.debug("⚙️ Starting conversion process")
        let extensionForFormat = format.preferredFilenameExtension ?? "mp4"
        let outputURL = try CacheManager.shared.createTemporaryURL(for: extensionForFormat)
        
        logger.debug("📂 Output will be written to: \(outputURL.path)")
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: settings.videoQuality) else {
            logger.error("❌ Failed to create AVAssetExportSession for the given asset and preset")
            throw ConversionError.exportFailed(reason: "Failed to create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        // Apply optional audio mix
        if let audioMix = try? await createAudioMix(for: asset) {
            logger.debug("🎵 Applying audio mix to export session")
            exportSession.audioMix = audioMix
        }
        
        // Apply video composition if needed
        if format.conforms(to: .audiovisualContent) {
            if let videoComposition = try? await createVideoComposition(for: asset) {
                logger.debug("🎥 Applying video composition to export session")
                exportSession.videoComposition = videoComposition
            } else {
                logger.debug("🎥 No video composition applied")
            }
        }
        
        logger.debug("▶️ Starting export session")
        
        let progressTask = Task {
            while !Task.isCancelled {
                let currentProgress = exportSession.progress
                progress.completedUnitCount = Int64(currentProgress * 100)
                logger.debug("📊 Export progress: \(Int(currentProgress * 100))%")
                try? await Task.sleep(nanoseconds: 100_000_000)
                if exportSession.status != .exporting { break }
            }
        }
        
        await exportSession.export()
        progressTask.cancel()
        
        switch exportSession.status {
        case .completed:
            logger.debug("✅ Export completed successfully")
            let resultMetadata = try await extractMetadata(from: asset)
            return ProcessingResult(
                outputURL: outputURL,
                originalFileName: metadata.originalFileName ?? originalURL.lastPathComponent,
                suggestedFileName: "converted_video." + extensionForFormat,
                fileType: format,
                metadata: resultMetadata
            )
        case .failed:
            let errorMessage = exportSession.error?.localizedDescription ?? "Unknown error"
            logger.error("❌ Export failed: \(errorMessage)")
            throw ConversionError.conversionFailed(reason: "Export failed: \(errorMessage)")
        case .cancelled:
            logger.error("❌ Export cancelled")
            throw ConversionError.conversionFailed(reason: "Export cancelled")
        default:
            logger.error("❌ Export ended with unexpected status: \(exportSession.status.rawValue)")
            throw ConversionError.conversionFailed(reason: "Unexpected export status: \(exportSession.status.rawValue)")
        }
    }
    
    func extractKeyFrame(from asset: AVAsset, format: UTType, metadata: ConversionMetadata) async throws -> ProcessingResult {
        logger.debug("🖼 Extracting key frame from video")
        
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        // Extract first frame
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        let imageRef = try await generator.image(at: time).image
        
        let imageExtension = format.preferredFilenameExtension ?? "jpg"
        let outputURL = try CacheManager.shared.createTemporaryURL(for: imageExtension)
        
        let nsImage = NSImage(cgImage: imageRef, size: NSSize(width: imageRef.width, height: imageRef.height))
        try await imageProcessor.saveImage(nsImage, format: format, to: outputURL, metadata: metadata)
        
        logger.debug("✅ Key frame extracted and saved")
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "frame",
            suggestedFileName: "extracted_frame." + imageExtension,
            fileType: format,
            metadata: nil
        )
    }
    
    private func createVideoComposition(for asset: AVAsset) async throws -> AVMutableVideoComposition {
        logger.debug("🎥 Creating video composition")
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            logger.error("❌ No video track found for composition")
            throw ConversionError.conversionFailed(reason: "No video track found")
        }
        
        let trackSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        
        let targetSize = settings.maintainAspectRatio
            ? calculateAspectFitSize(trackSize, target: settings.targetSize)
            : settings.targetSize
        
        let composition = AVMutableVideoComposition()
        composition.renderSize = targetSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        
        return composition
    }
    
    private func calculateAspectFitSize(_ originalSize: CGSize, target: CGSize) -> CGSize {
        let widthRatio = target.width / originalSize.width
        let heightRatio = target.height / originalSize.height
        let scale = min(widthRatio, heightRatio)
        return CGSize(width: originalSize.width * scale, height: originalSize.height * scale)
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
    
    func extractAudio(
        from asset: AVAsset,
        to format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        logger.debug("🎵 Starting direct audio extraction")
        
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            logger.error("❌ No audio track found in the video")
            throw ConversionError.conversionFailed(reason: "No audio track found in video")
        }
        
        // Create export session with audio-specific preset
        let preset = AVAssetExportPresetAppleM4A
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            logger.error("❌ Failed to create export session for audio extraction")
            throw ConversionError.conversionFailed(reason: "Failed to create export session for audio")
        }
        
        // Set up export parameters
        let extensionForAudio = format == .mp3 ? "m4a" : format.preferredFilenameExtension ?? "m4a"
        let outputURL = try CacheManager.shared.createTemporaryURL(for: extensionForAudio)
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        
        // Track progress
        let progressTask = Task {
            while !Task.isCancelled {
                let currentProgress = exportSession.progress
                progress.completedUnitCount = Int64(currentProgress * 100)
                logger.debug("📊 Audio export progress: \(Int(currentProgress * 100))%")
                try? await Task.sleep(nanoseconds: 100_000_000)
                if exportSession.status != .exporting { break }
            }
        }
        
        logger.debug("▶️ Starting audio extraction")
        await exportSession.export()
        progressTask.cancel()
        
        switch exportSession.status {
        case .completed:
            logger.debug("✅ Audio extraction completed")
            
            // If MP3 is requested, convert M4A to MP3
            if format == .mp3 {
                return try await convertM4AToMP3(outputURL, metadata: metadata)
            }
            
            let resultMetadata = try await extractMetadata(from: asset)
            return ProcessingResult(
                outputURL: outputURL,
                originalFileName: metadata.originalFileName ?? "audio",
                suggestedFileName: "extracted_audio." + extensionForAudio,
                fileType: format,
                metadata: resultMetadata
            )
            
        case .failed:
            let errorMessage = exportSession.error?.localizedDescription ?? "Unknown error"
            logger.error("❌ Audio extraction failed: \(errorMessage)")
            throw ConversionError.exportFailed(reason: "Failed to extract audio: \(errorMessage)")
            
        case .cancelled:
            logger.error("❌ Audio extraction cancelled")
            throw ConversionError.exportFailed(reason: "Audio extraction was cancelled")
            
        default:
            let statusRaw = exportSession.status.rawValue
            logger.error("❌ Audio extraction ended with unexpected status: \(statusRaw)")
            throw ConversionError.exportFailed(reason: "Unexpected export status: \(statusRaw)")
        }
    }
    
    private func convertM4AToMP3(_ inputURL: URL, metadata: ConversionMetadata) async throws -> ProcessingResult {
        logger.debug("🎵 Converting M4A to MP3")
        
        // First create a temporary M4A file
        let tempM4AURL = try await CacheManager.shared.createTemporaryURL(for: "m4a")
        let asset = AVURLAsset(url: inputURL)
        
        // Create export session with audio preset
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ConversionError.exportFailed(reason: "Failed to create export session for MP3 conversion")
        }
        
        exportSession.outputURL = tempM4AURL
        exportSession.outputFileType = .m4a
        exportSession.audioTimePitchAlgorithm = .spectral
        
        logger.debug("▶️ Starting M4A export")
        await exportSession.export()
        
        switch exportSession.status {
        case .completed:
            logger.debug("✅ M4A export completed successfully")
            
            // Create final MP3 URL
            let mp3URL = try await CacheManager.shared.createTemporaryURL(for: "mp3")
            
            // Ensure we have write permissions for the output directory
            let outputDirectory = mp3URL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            
            // Remove any existing file at the destination
            if FileManager.default.fileExists(atPath: mp3URL.path) {
                try FileManager.default.removeItem(at: mp3URL)
            }
            
            // Move the M4A file to MP3
            try FileManager.default.moveItem(at: tempM4AURL, to: mp3URL)
            
            logger.debug("✅ File successfully moved to: \(mp3URL.path)")
            
            return ProcessingResult(
                outputURL: mp3URL,
                originalFileName: metadata.originalFileName ?? "audio",
                suggestedFileName: "converted_audio.mp3",
                fileType: .mp3,
                metadata: metadata.toDictionary()
            )
            
        case .failed:
            let errorMessage = exportSession.error?.localizedDescription ?? "Unknown error"
            logger.error("❌ MP3 conversion failed: \(errorMessage)")
            throw ConversionError.exportFailed(reason: "Failed to convert to MP3: \(errorMessage)")
            
        case .cancelled:
            logger.error("❌ MP3 conversion cancelled")
            throw ConversionError.exportFailed(reason: "MP3 conversion was cancelled")
            
        default:
            let statusRaw = exportSession.status.rawValue
            logger.error("❌ MP3 conversion ended with unexpected status: \(statusRaw)")
            throw ConversionError.exportFailed(reason: "Unexpected export status: \(statusRaw)")
        }
    }
}
