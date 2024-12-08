import AVFoundation
import CoreGraphics
import AppKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
    category: "AudioProcessor"
)

class AudioProcessor: BaseConverter {
    private let visualizer: AudioVisualizer
    private let imageProcessor: ImageProcessor
    private let resourcePool: ResourcePool
    private let progressTracker: ProgressTracker
    private var config: AudioProcessorConfig
    
    required init(settings: ConversionSettings = ConversionSettings()) throws {
        // Force 1080p for the visualization
        var customConfig = AudioProcessorConfig.default
        customConfig.waveformSize = CGSize(width: 1920, height: 1080)
        self.config = customConfig
        
        self.resourcePool = ResourcePool.shared
        self.visualizer = AudioVisualizer(size: self.config.waveformSize)
        self.imageProcessor = try ImageProcessor(settings: settings)
        self.progressTracker = ProgressTracker()
        try super.init(settings: settings)
    }
    
    init(settings: ConversionSettings = ConversionSettings(), 
         config: AudioProcessorConfig = .default) throws {
        var customConfig = config
        // Ensure 1080p for the visualization
        customConfig.waveformSize = CGSize(width: 1920, height: 1080)
        try customConfig.validate()
        
        guard settings.videoBitRate > 0 else {
            throw ConversionError.invalidConfiguration("Video bitrate must be positive")
        }
        guard settings.audioBitRate > 0 else {
            throw ConversionError.invalidConfiguration("Audio bitrate must be positive")
        }
        
        self.config = customConfig
        self.resourcePool = ResourcePool.shared
        self.visualizer = AudioVisualizer(size: self.config.waveformSize)
        self.imageProcessor = try ImageProcessor(settings: settings)
        self.progressTracker = ProgressTracker()
        try super.init(settings: settings)
    }
    
    override func canConvert(from: UTType, to: UTType) -> Bool {
        switch (from, to) {
        case (let f, _) where f.conforms(to: .audio):
            return true
        case (_, let t) where t.conforms(to: .image) || t.conforms(to: .audiovisualContent):
            return true
        default:
            return false
        }
    }
    
    override func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        await updateConversionStage(.analyzing)
        
        logger.debug("🎵 Starting audio conversion process")
        logger.debug("📂 Input file: \(url.path)")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ConversionError.invalidInput
            }
            
            let taskId = UUID()
            logger.debug("🔑 Starting conversion task: \(taskId.uuidString)")
            
            return try await withThrowingTaskGroup(of: ProcessingResult.self) { group in
                let result = try await group.addTask {
                    await self.resourcePool.beginTask(id: taskId, type: .audio)
                    defer {
                        Task {
                            await self.resourcePool.endTask(id: taskId)
                        }
                    }
                    
                    let asset = AVAsset(url: url)
                    try await self.validateAudioAsset(asset)
                    
                    await self.updateConversionStage(.preparing)
                    
                    let strategy = try await self.determineConversionStrategy(from: asset, to: format)
                    let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
                    
                    await self.updateConversionStage(.converting)
                    
                    let conversionResult = try await self.withTimeout(seconds: 300) {
                        try await self.executeConversion(
                            asset: asset,
                            to: outputURL,
                            format: format,
                            strategy: strategy,
                            progress: progress,
                            metadata: metadata
                        )
                    }
                    
                    await self.updateConversionStage(.optimizing)
                    
                    guard FileManager.default.fileExists(atPath: conversionResult.outputURL.path) else {
                        throw ConversionError.exportFailed(reason: "Output file not found")
                    }
                    
                    await self.updateConversionStage(.completed)
                    return conversionResult
                }
                
                let finalResult = try await group.next()
                guard let res = finalResult else {
                    throw ConversionError.conversionFailed(reason: "No result from conversion")
                }
                return res
            }
            
        } catch let error as ConversionError {
            await updateConversionStage(.failed)
            logger.error("❌ Conversion failed: \(error.localizedDescription)")
            throw error
        } catch {
            await updateConversionStage(.failed)
            logger.error("❌ Unexpected error: \(error.localizedDescription)")
            throw ConversionError.conversionFailed(reason: error.localizedDescription)
        }
    }
    
    private func validateAudioAsset(_ asset: AVAsset) async throws {
        guard try await asset.loadTracks(withMediaType: .audio).first != nil else {
            throw ConversionError.invalidInput
        }
        
        let duration = try await asset.load(.duration)
        guard duration.seconds > 0 else {
            throw ConversionError.invalidInput
        }
    }
    
    private func determineConversionStrategy(from asset: AVAsset, to format: UTType) async throws -> ConversionStrategy {
        logger.debug("Determining conversion strategy for format: \(format.identifier)")
        
        let strategy: ConversionStrategy
        
        switch format {
        case _ where format.conforms(to: .audiovisualContent):
            logger.debug("Selected visualization strategy for audiovisual content")
            strategy = .visualize
            
        case _ where format.conforms(to: .image):
            logger.debug("Selected visualization strategy for image output")
            strategy = .visualize
            
        case _ where format.conforms(to: .audio):
            logger.debug("Selected direct conversion strategy for audio output")
            strategy = .direct
            
        default:
            logger.error("No suitable conversion strategy found")
            throw ConversionError.incompatibleFormats(from: .audio, to: format)
        }
        
        guard await checkStrategySupport(strategy) else {
            throw ConversionError.unsupportedConversion("Strategy \(strategy) is not supported")
        }
        
        return strategy
    }
    
    private func executeConversion(
        asset: AVAsset,
        to outputURL: URL,
        format: UTType,
        strategy: ConversionStrategy,
        progress: Progress,
        metadata: ConversionMetadata
    ) async throws -> ProcessingResult {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .processingStageChanged,
                object: nil,
                userInfo: ["stage": ConversionStage.converting]
            )
        }

        switch strategy {
        case .direct:
            return try await convertAudioFormat(
                from: asset,
                to: outputURL,
                format: format,
                metadata: metadata,
                progress: progress
            )
        case .visualize:
            if format.conforms(to: .audiovisualContent) {
                // Create a video with visualization and embed original audio
                return try await createVisualizedVideo(
                    from: asset,
                    to: outputURL,
                    format: format,
                    metadata: metadata,
                    progress: progress
                )
            } else {
                return try await createWaveformImage(
                    from: asset,
                    to: format,
                    metadata: metadata,
                    progress: progress
                )
            }
        default:
            throw ConversionError.incompatibleFormats(from: .audio, to: format)
        }
    }
    
    private func convertAudioFormat(
        from asset: AVAsset,
        to outputURL: URL,
        format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        logger.debug("Converting audio format")
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: settings.videoQuality) else {
            throw ConversionError.exportFailed(reason: "Failed to create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed(reason: "Audio export failed")
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "audio",
            suggestedFileName: "converted_audio." + (format.preferredFilenameExtension ?? "m4a"),
            fileType: format,
            metadata: metadata.toDictionary()
        )
    }
    
    private func createVisualizedVideo(
        from asset: AVAsset,
        to outputURL: URL,
        format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        let videoFormat = UTType.mpeg4Movie
        logger.debug("🎨 Creating audio visualization with format: \(videoFormat.identifier)")
        
        let duration = try await asset.load(.duration)
        let fps = Double(settings.frameRate)
        let totalFrames = Int(duration.seconds * fps)
        
        logger.debug("⚙️ Generating \(totalFrames) frames for \(duration.seconds) seconds")
        
        // Generate visualization frames at 1080p
        let frames = try await visualizer.generateVisualizationFrames(
            for: asset,
            frameCount: totalFrames
        ) { frameProgress in
            Task { @MainActor in
                let completed = Int64(frameProgress * 75)
                progress.totalUnitCount = 100
                progress.completedUnitCount = completed
                NotificationCenter.default.post(
                    name: .processingProgressUpdated,
                    object: nil,
                    userInfo: ["progress": frameProgress]
                )
            }
        }
        
        // Create a silent video track from the frames
        let tempVideoResult = try await visualizer.createVideoTrack(
            from: frames,
            duration: duration,
            settings: settings,
            outputURL: outputURL,
            progressHandler: { videoProgress in
                Task { @MainActor in
                    let overallProgress = 0.75 + (videoProgress * 0.25)
                    progress.completedUnitCount = Int64(overallProgress * 100)
                    NotificationCenter.default.post(
                        name: .processingProgressUpdated,
                        object: nil,
                        userInfo: ["progress": overallProgress]
                    )
                }
            }
        )
        
        // Now we have a video file with no audio. We must merge original audio.
        let finalURL = try await mergeAudio(from: asset, withVideoAt: tempVideoResult.outputURL)
        
        return ProcessingResult(
            outputURL: finalURL,
            originalFileName: metadata.originalFileName ?? "audio_visualization",
            suggestedFileName: "visualized_audio.mp4",
            fileType: videoFormat,
            metadata: metadata.toDictionary()
        )
    }
    
    // Merge the original audio from 'asset' with the silent visualization video at 'videoURL'
    private func mergeAudio(from asset: AVAsset, withVideoAt videoURL: URL) async throws -> URL {
        let videoAsset = AVAsset(url: videoURL)
        
        let composition = AVMutableComposition()
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ),
              let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
              let compAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ConversionError.conversionFailed(reason: "Failed to prepare tracks")
        }
        
        let videoDuration = try await videoAsset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: videoDuration)
        
        try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        
        // Insert original audio, trimming if necessary
        let audioDuration = try await asset.load(.duration)
        let shorterDuration = min(videoDuration, audioDuration)
        let audioRange = CMTimeRange(start: .zero, duration: shorterDuration)
        try compAudioTrack.insertTimeRange(audioRange, of: audioTrack, at: .zero)
        
        let finalURL = try await CacheManager.shared.createTemporaryURL(for: "mp4")
        
        guard let exportSession = AVAssetExportSession(asset: composition, presetName: settings.videoQuality) else {
            throw ConversionError.exportFailed(reason: "Failed to create final export session")
        }
        exportSession.outputURL = finalURL
        exportSession.outputFileType = .mp4
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed(reason: "Failed to finalize merged video")
        }
        
        return finalURL
    }
    
    private func copyAudioTrack(from asset: AVAsset, to audioInput: AVAssetWriterInput) async throws {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.conversionFailed(reason: "No audio track found")
        }
        
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]
        )
        
        reader.add(output)
        if !reader.startReading() {
            throw ConversionError.conversionFailed(reason: "Failed to start reading audio")
        }
        
        while let buffer = output.copyNextSampleBuffer() {
            if !audioInput.append(buffer) {
                throw ConversionError.conversionFailed(reason: "Failed to append audio buffer")
            }
        }
    }
    
    func createWaveformImage(
        from asset: AVAsset,
        to format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        logger.debug("📊 Starting waveform generation")
        
        let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "png")
        
        do {
            // Generate a waveform image at high resolution
            let waveformImage = try await visualizer.generateWaveformImage(for: asset, size: CGSize(width: 1920, height: 1080))
            let nsImage = NSImage(cgImage: waveformImage, size: NSSize(width: waveformImage.width, height: waveformImage.height))
            
            try await imageProcessor.saveImage(
                nsImage,
                format: format,
                to: outputURL,
                metadata: metadata
            )
            
            return ProcessingResult(
                outputURL: outputURL,
                originalFileName: metadata.originalFileName ?? "waveform",
                suggestedFileName: "waveform." + (format.preferredFilenameExtension ?? "png"),
                fileType: format,
                metadata: metadata.toDictionary()
            )
        } catch {
            logger.error("❌ Waveform generation failed: \(error.localizedDescription)")
            throw ConversionError.conversionFailed(reason: "Failed to generate waveform")
        }
    }
    
    override func validateConversion(from inputType: UTType, to outputType: UTType) throws -> ConversionStrategy {
        guard canConvert(from: inputType, to: outputType) else {
            throw ConversionError.incompatibleFormats(from: inputType, to: outputType)
        }
        
        if inputType.conforms(to: .audio) {
            if outputType.conforms(to: .audiovisualContent) {
                return .visualize
            } else if outputType.conforms(to: .image) {
                return .visualize
            } else if outputType.conforms(to: .audio) {
                return .direct
            }
        }
        
        throw ConversionError.incompatibleFormats(from: inputType, to: outputType)
    }
    
    private func checkStrategySupport(_ strategy: ConversionStrategy) -> Bool {
        switch strategy {
        case .direct, .visualize:
            return true
        default:
            return false
        }
    }
    
    private func updateConversionStage(_ stage: ConversionStage) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .processingStageChanged,
                object: nil,
                userInfo: ["stage": stage]
            )
        }
    }
    
    private func createExportSession(for asset: AVAsset, format: UTType) async throws -> AVAssetExportSession {
        guard let session = AVAssetExportSession(asset: asset, presetName: settings.videoQuality) else {
            throw ConversionError.exportFailed(reason: "Failed to create export session")
        }
        return session
    }
}