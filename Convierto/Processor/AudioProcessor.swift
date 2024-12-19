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
        // Audio to audio - check both conform to audio type
        if from.conforms(to: .audio) && to.conforms(to: .audio) {
            return true
        }
        
        // Audio to video/image (visualization)
        if from.conforms(to: .audio) && 
           (to.conforms(to: .audiovisualContent) || to.conforms(to: .image)) {
            return true
        }
        
        return false
    }
    
    override func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        await updateConversionStage(.analyzing)
        
        logger.debug("🎵 Starting audio conversion process")
        logger.debug("📂 Input file: \(url.path)")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        do {
            // Validate input file exists
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ConversionError.invalidInput
            }
            
            let taskId = UUID()
            logger.debug("🔑 Starting conversion task: \(taskId.uuidString)")
            
            return try await withThrowingTaskGroup(of: ProcessingResult.self) { group in
                let result = try await group.addTask {
                    // Acquire resource lock
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
                    
                    // Validate output exists
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
        
        // Verify the asset has audio tracks
        guard try await asset.loadTracks(withMediaType: .audio).first != nil else {
            throw ConversionError.invalidInput
        }
        
        if format.conforms(to: .audio) {
            logger.debug("Selected direct conversion strategy for audio output")
            return .direct
        }
        
        if format.conforms(to: .audiovisualContent) || format.conforms(to: .image) {
            logger.debug("Selected visualization strategy")
            return .visualize
        }
        
        throw ConversionError.unsupportedConversion("Unsupported output format: \(format.identifier)")
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
        logger.debug("🎵 Converting audio format to \(format.identifier)")
        
        if format == .wav || format.identifier == "com.microsoft.waveform-audio" {
            // Use AVAssetWriter for WAV conversion
            return try await convertToWAV(from: asset, to: outputURL, metadata: metadata, progress: progress)
        }
        
        // For MP3 conversion, we'll first convert to M4A then use an encoder to convert to MP3
        if format == .mp3 {
            return try await convertToMP3(from: asset, metadata: metadata, progress: progress)
        }
        
        // For other formats, use AVAssetExportSession
        let presetName = try determineAudioPreset(for: format)
        logger.debug("📝 Using preset: \(presetName)")
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw ConversionError.exportFailed(reason: "Failed to create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        
        // Track export progress
        let progressTask = Task {
            while !Task.isCancelled {
                await MainActor.run {
                    progress.completedUnitCount = Int64(exportSession.progress * 100)
                    NotificationCenter.default.post(
                        name: .processingProgressUpdated,
                        object: nil,
                        userInfo: ["progress": exportSession.progress]
                    )
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        
        await exportSession.export()
        progressTask.cancel()
        
        if let error = exportSession.error {
            logger.error("❌ Export failed: \(error.localizedDescription)")
            throw ConversionError.exportFailed(reason: error.localizedDescription)
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "audio",
            suggestedFileName: "converted_audio." + (format.preferredFilenameExtension ?? "m4a"),
            fileType: format,
            metadata: metadata.toDictionary()
        )
    }
    
    private func convertToMP3(
        from asset: AVAsset,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        logger.debug("🎵 Starting MP3 conversion process")
        
        // First convert to M4A as intermediate format
        let intermediateURL = try await CacheManager.shared.createTemporaryURL(for: "m4a")
        let finalURL = try await CacheManager.shared.createTemporaryURL(for: "mp3")
        
        // Create export session for M4A
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ConversionError.exportFailed(reason: "Failed to create export session")
        }
        
        exportSession.outputURL = intermediateURL
        exportSession.outputFileType = .m4a
        
        // Track progress for first half of conversion
        let progressTask = Task {
            while !Task.isCancelled {
                await MainActor.run {
                    let halfProgress = exportSession.progress * 0.5
                    progress.completedUnitCount = Int64(halfProgress * 100)
                    NotificationCenter.default.post(
                        name: .processingProgressUpdated,
                        object: nil,
                        userInfo: ["progress": halfProgress]
                    )
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        
        await exportSession.export()
        progressTask.cancel()
        
        if let error = exportSession.error {
            logger.error("❌ M4A export failed: \(error.localizedDescription)")
            throw ConversionError.exportFailed(reason: error.localizedDescription)
        }
        
        // Now convert M4A to MP3 using AVAssetReader/Writer
        let m4aAsset = AVAsset(url: intermediateURL)
        try await convertM4AToMP3(m4aAsset, to: finalURL, progress: progress)
        
        // Clean up intermediate file
        try? FileManager.default.removeItem(at: intermediateURL)
        
        return ProcessingResult(
            outputURL: finalURL,
            originalFileName: metadata.originalFileName ?? "audio",
            suggestedFileName: "converted_audio.mp3",
            fileType: .mp3,
            metadata: metadata.toDictionary()
        )
    }
    
    private func convertM4AToMP3(
        _ asset: AVAsset,
        to outputURL: URL,
        progress: Progress
    ) async throws {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.conversionFailed(reason: "No audio track found")
        }
        
        // Create asset reader
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw ConversionError.conversionFailed(reason: "Failed to create asset reader")
        }
        
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEGLayer3,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: settings.audioBitRate
        ]
        
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2
            ]
        )
        
        reader.add(readerOutput)
        
        // Create asset writer
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp3) else {
            throw ConversionError.conversionFailed(reason: "Failed to create asset writer")
        }
        
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        writer.add(writerInput)
        
        guard reader.startReading() else {
            throw ConversionError.conversionFailed(reason: "Failed to start reading")
        }
        
        guard writer.startWriting() else {
            throw ConversionError.conversionFailed(reason: "Failed to start writing")
        }
        
        writer.startSession(atSourceTime: .zero)
        
        await withCheckedContinuation { continuation in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.convierto.mp3conversion")) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        break
                    }
                }
            }
        }
        
        await writer.finishWriting()
        
        if writer.status == .failed {
            throw ConversionError.conversionFailed(reason: writer.error?.localizedDescription ?? "Unknown error")
        }
    }
    
    private func convertToWAV(
        from asset: AVAsset,
        to outputURL: URL,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        logger.debug("🎵 Converting to WAV format")
        
        // Get the audio track
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.conversionFailed(reason: "No audio track found")
        }
        
        // Create asset reader
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw ConversionError.conversionFailed(reason: "Failed to create asset reader")
        }
        
        // Configure output settings for WAV
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: outputSettings
        )
        reader.add(readerOutput)
        
        // Create asset writer
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .wav) else {
            throw ConversionError.conversionFailed(reason: "Failed to create asset writer")
        }
        
        // Configure writer input
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        writer.add(writerInput)
        
        // Start reading/writing
        guard reader.startReading() else {
            throw ConversionError.conversionFailed(reason: "Failed to start reading")
        }
        
        guard writer.startWriting() else {
            throw ConversionError.conversionFailed(reason: "Failed to start writing")
        }
        
        writer.startSession(atSourceTime: .zero)
        
        // Process audio samples
        while reader.status == .reading {
            if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                if writerInput.isReadyForMoreMediaData {
                    writerInput.append(sampleBuffer)
                } else {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
            } else {
                writerInput.markAsFinished()
                break
            }
        }
        
        // Finish writing
        await writer.finishWriting()
        
        if writer.status == .failed {
            throw ConversionError.conversionFailed(reason: writer.error?.localizedDescription ?? "Unknown error")
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "audio",
            suggestedFileName: "converted_audio.wav",
            fileType: .wav,
            metadata: metadata.toDictionary()
        )
    }
    
    private func determineAudioPreset(for format: UTType) throws -> String {
        switch format {
        case _ where format == .wav || format.identifier == "com.microsoft.waveform-audio":
            return AVAssetExportPresetAppleM4A // Use M4A preset for WAV conversion
        case _ where format == .mp3:
            return AVAssetExportPresetAppleM4A
        case _ where format == .m4a:
            return AVAssetExportPresetAppleM4A
        case _ where format.conforms(to: .audio):
            logger.debug("⚠️ Generic audio format, using highest quality preset")
            return AVAssetExportPresetHighestQuality
        default:
            throw ConversionError.unsupportedConversion("Unsupported audio format: \(format.identifier)")
        }
    }
    
    private func getAudioSettings(for format: UTType) -> [String: Any] {
        switch format {
        case _ where format == .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2
            ]
        default:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioBitRate
            ]
        }
    }
    
    override func getAVFileType(for format: UTType) -> AVFileType {
        switch format {
        case _ where format == .wav || format.identifier == "com.microsoft.waveform-audio":
            return .wav
        case _ where format == .mp3:
            return .mp3
        case _ where format == .m4a:
            return .m4a
        case _ where format == .aac:
            return .m4a
        default:
            logger.debug("⚠️ Unknown format, defaulting to M4A: \(format.identifier)")
            return .m4a
        }
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
        logger.debug("🔍 Validating conversion from \(inputType.identifier) to \(outputType.identifier)")
        
        // Both types must be audio for direct conversion
        guard inputType.conforms(to: .audio) else {
            throw ConversionError.incompatibleFormats(
                from: inputType,
                to: outputType,
                reason: "Input format is not audio"
            )
        }
        
        if outputType.conforms(to: .audio) {
            logger.debug("✅ Audio to audio conversion validated")
            return .direct
        }
        
        if outputType.conforms(to: .audiovisualContent) || outputType.conforms(to: .image) {
            logger.debug("✅ Audio visualization conversion validated")
            return .visualize
        }
        
        throw ConversionError.incompatibleFormats(
            from: inputType,
            to: outputType,
            reason: "Unsupported conversion"
        )
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