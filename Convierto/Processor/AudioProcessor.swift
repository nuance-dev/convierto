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
    private let config: AudioProcessorConfig
    
    required init(settings: ConversionSettings = ConversionSettings()) throws {
        self.config = .default
        self.resourcePool = ResourcePool.shared
        self.visualizer = AudioVisualizer(size: config.waveformSize)
        self.imageProcessor = try ImageProcessor(settings: settings)
        self.progressTracker = ProgressTracker()
        try super.init(settings: settings)
    }
    
    init(settings: ConversionSettings = ConversionSettings(), 
         config: AudioProcessorConfig = .default) throws {
        self.config = config
        try config.validate()
        
        guard settings.videoBitRate > 0 else {
            throw ConversionError.invalidConfiguration("Video bitrate must be positive")
        }
        guard settings.audioBitRate > 0 else {
            throw ConversionError.invalidConfiguration("Audio bitrate must be positive")
        }
        
        self.resourcePool = ResourcePool.shared
        self.visualizer = AudioVisualizer(size: config.waveformSize)
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
        // Add stage notification at the start
        await updateConversionStage(.analyzing)
        
        logger.debug("🎵 Starting audio conversion process")
        logger.debug("📂 Input file: \(url.path)")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        do {
            // Validate input early
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ConversionError.invalidInput
            }
            
            let taskId = UUID()
            logger.debug("🔑 Starting conversion task: \(taskId.uuidString)")
            
            // Resource management using structured concurrency
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
                
                // Wait for the task to complete and get its result
                let finalResult = try await group.next()
                guard let result = finalResult else {
                    throw ConversionError.conversionFailed(reason: "Task group completed without result")
                }
                return result
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
        
        // Verify strategy is supported
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
        // Update stage
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
        
        let composition = AVMutableComposition()
        
        // Add audio track to composition
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        } else {
            throw ConversionError.conversionFailed(reason: "Failed to create audio track")
        }
        
        // Create export session with composition
        guard let exportSession = try? await AVAssetExportSession(
            asset: asset,
            presetName: settings.videoQuality
        ) else {
            throw ConversionError.exportFailed(reason: "Failed to create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        // Apply audio mix if needed
        if let audioMix = try await createAudioMix(for: composition) {
            exportSession.audioMix = audioMix
        }
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed(reason: "Export session failed to complete")
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "audio",
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
        
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        
        // Store the URL in a property to prevent cleanup
        let tempURL = outputURL
        logger.debug("📝 Using output URL: \(tempURL.path)")
        
        // Configure progress tracking
        progress.totalUnitCount = 100
        progress.completedUnitCount = 0
        
        let duration = try await asset.load(.duration)
        let fps = 30
        let totalFrames = min(Int(duration.seconds * Double(fps)), 1800)
        
        logger.debug("⚙️ Generating \(totalFrames) frames for \(duration.seconds) seconds")
        
        let frames = try await visualizer.generateVisualizationFrames(
            for: asset,
            frameCount: totalFrames
        ) { frameProgress in
            Task { @MainActor in
                progress.completedUnitCount = Int64(frameProgress * 75)
                NotificationCenter.default.post(
                    name: .processingProgressUpdated,
                    object: nil,
                    userInfo: ["progress": frameProgress]
                )
            }
        }
        
        // Create video writer with the stored URL
        let videoWriter = try AVAssetWriter(url: tempURL, fileType: .mp4)
        logger.debug("✅ Created video writer for: \(tempURL.path)")
        
        let result = try await visualizer.createVideoTrack(
            from: frames,
            duration: duration,
            settings: settings,
            outputURL: tempURL,
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
        
        // Ensure the file exists before returning
        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw ConversionError.exportFailed(reason: "Output file not found at: \(tempURL.path)")
        }
        
        return ProcessingResult(
            outputURL: tempURL,
            originalFileName: metadata.originalFileName ?? "audio_visualization",
            suggestedFileName: "visualized_audio.mp4",
            fileType: videoFormat,
            metadata: metadata.toDictionary()
        )
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
            let waveformImage = try await visualizer.generateWaveformImage(for: asset, size: CGSize(width: 1920, height: 480))
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
            throw ConversionError.conversionFailed(reason: "Failed to generate waveform: \(error.localizedDescription)")
        }
    }
    
    func extractAudioSamples(
        from asset: AVAsset,
        at time: CMTime,
        windowSize: Double
    ) async throws -> [Float] {
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
        guard reader.startReading() else {
            throw ConversionError.conversionFailed(reason: "Failed to start reading audio")
        }
        
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            if let audioBuffer = CMSampleBufferGetDataBuffer(buffer) {
                var blockBufferLength = 0
                var dataPointerOut: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    audioBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: &blockBufferLength,
                    totalLengthOut: nil,
                    dataPointerOut: &dataPointerOut
                )
                
                if status == kCMBlockBufferNoErr, let dataPointer = dataPointerOut {
                    let int16Pointer = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: Int16.self)
                    let bufferPointer = UnsafeBufferPointer(start: int16Pointer, count: blockBufferLength / 2)
                    let floatSamples = bufferPointer.map { Float($0) / Float(Int16.max) }
                    samples.append(contentsOf: floatSamples)
                }
            }
        }
        
        if samples.isEmpty {
            throw ConversionError.conversionFailed(reason: "No audio samples extracted")
        }
        
        return samples
    }

    private func generateWaveform(
        from samples: [Float],
        size: CGSize
    ) async throws -> CGImage {
        // Create context with error handling
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionError.conversionFailed(reason: "Failed to create graphics context")
        }
        
        // Process samples in chunks to avoid memory issues
        let chunkSize = 1024
        let samplesPerPixel = max(1, samples.count / Int(size.width))
        
        // Use the visualizer to process the waveform
        try await visualizer.processWaveform(
            samples: samples,
            context: context,
            size: size,
            chunkSize: chunkSize,
            samplesPerPixel: samplesPerPixel
        )
        
        guard let image = context.makeImage() else {
            throw ConversionError.conversionFailed(reason: "Failed to create waveform image")
        }
        
        return image
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
    
    func convert(
        _ asset: AVAsset,
        to outputURL: URL,
        format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        logger.debug("🎵 Starting audio conversion")
        
        let exportSession = try await createExportSession(
            for: asset,
            format: format
        )
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        if let audioMix = try await createAudioMix(for: asset) {
            exportSession.audioMix = audioMix
        }
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed(reason: "Export failed: \(String(describing: exportSession.error))")
        }
        
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ConversionError.exportFailed(reason: "Output file not found")
        }
        
        await updateConversionStage(.completed)
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "audio",
            suggestedFileName: "converted_audio." + (format.preferredFilenameExtension ?? "m4a"),
            fileType: format,
            metadata: metadata.toDictionary()
        )
    }
    
    func createPixelBuffer(from image: NSImage) throws -> CVPixelBuffer {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw ConversionError.conversionFailed(reason: "Failed to create pixel buffer")
        }
        
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        defer { CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0)) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ConversionError.conversionFailed(reason: "Failed to create graphics context")
        }
        
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        
        return buffer
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
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: nil
        )
        
        videoWriter.add(videoInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        
        if let pixelBuffer = try? createPixelBuffer(from: image) {
            adaptor.append(pixelBuffer, withPresentationTime: .zero)
        }
        
        videoInput.markAsFinished()
        await videoWriter.finishWriting()
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "image",
            suggestedFileName: "converted_video." + (format.preferredFilenameExtension ?? "mp4"),
            fileType: format,
            metadata: nil
        )
    }
    
    private func checkStrategySupport(_ strategy: ConversionStrategy) -> Bool {
        switch strategy {
        case .direct:
            return true
        case .visualize:
            return true
        default:
            return false
        }
    }
    
    // Helper method for stage updates
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
        let exportSession = try await AVAssetExportSession(
            asset: asset,
            presetName: settings.videoQuality
        )

        guard let session = exportSession else {
            throw ConversionError.exportFailed(reason: "Failed to create export session")
        }

        return session
    }
}
