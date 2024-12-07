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
    private let maxBufferSize: Int = 1024 * 1024 // 1MB buffer size
    
    required init(settings: ConversionSettings = ConversionSettings()) {
        self.resourcePool = ResourcePool.shared
        self.visualizer = AudioVisualizer(size: CGSize(width: 1920, height: 1080))
        self.imageProcessor = ImageProcessor(settings: settings)
        self.progressTracker = ProgressTracker()
        super.init(settings: settings)
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
        await MainActor.run {
            NotificationCenter.default.post(
                name: .processingStageChanged,
                object: nil,
                userInfo: ["stage": ConversionStage.analyzing]
            )
        }
        
        logger.debug("🎵 Starting audio conversion process")
        logger.debug("📂 Input file: \(url.path)")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        // Validate settings
        guard settings.videoBitRate > 0 else {
            throw ConversionError.conversionFailed(reason: "Invalid video bitrate configuration")
        }
        
        guard settings.audioBitRate > 0 else {
            throw ConversionError.conversionFailed(reason: "Invalid audio bitrate configuration")
        }
        
        let taskId = UUID()
        logger.debug("🔑 Task ID: \(taskId.uuidString)")
        
        // Create a cleanup task that will run after conversion
        defer {
            Task {
                await resourcePool.endTask(id: taskId)
                logger.debug("🧹 Cleanup completed for task: \(taskId.uuidString)")
            }
        }
        
        await resourcePool.beginTask(id: taskId, type: .audio)
        
        do {
            let asset = AVAsset(url: url)
            try await asset.load(.tracks)
            logger.debug("📼 Asset created successfully")
            
            // Update stage to analyzing
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .processingStageChanged,
                    object: nil,
                    userInfo: ["stage": ConversionStage.analyzing]
                )
            }
            
            try await validateAudioAsset(asset)
            logger.debug("✅ Asset validation passed")
            
            try await resourcePool.checkResourceAvailability(taskId: taskId, type: .audio)
            logger.debug("✅ Resource availability confirmed")
            
            let strategy = try determineConversionStrategy(from: asset, to: format)
            logger.debug("⚙️ Conversion strategy determined: \(String(describing: strategy))")
            
            let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
            await resourcePool.markFileAsActive(outputURL)
            
            defer {
                Task {
                    await resourcePool.markFileAsInactive(outputURL)
                }
            }
            
            // Update stage to converting
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .processingStageChanged,
                    object: nil,
                    userInfo: ["stage": ConversionStage.converting]
                )
            }
            
            let result = try await withTimeout(seconds: 300) {
                logger.debug("⏳ Starting conversion with 300s timeout")
                return try await self.executeConversion(
                    asset: asset,
                    to: outputURL,
                    format: format,
                    strategy: strategy,
                    progress: progress,
                    metadata: metadata
                )
            }
            
            // Update stage to finishing
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .processingStageChanged,
                    object: nil,
                    userInfo: ["stage": ConversionStage.optimizing]
                )
            }
            
            logger.debug("✅ Conversion completed successfully")
            
            // Update stage to completed
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .processingStageChanged,
                    object: nil,
                    userInfo: ["stage": ConversionStage.completed]
                )
            }
            
            return result
            
        } catch let conversionError as ConversionError {
            logger.error("❌ Conversion failed: \(conversionError.localizedDescription)")
            throw conversionError
        } catch {
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
    
    private func determineConversionStrategy(from asset: AVAsset, to format: UTType) throws -> ConversionStrategy {
        if format.conforms(to: .audiovisualContent) {
            return .visualize
        } else if format.conforms(to: .image) {
            return .extractFrame
        } else if format.conforms(to: .audio) {
            return .direct
        }
        throw ConversionError.incompatibleFormats(from: .audio, to: format)
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
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
              let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ConversionError.conversionFailed(reason: "Failed to create audio track")
        }
        
        let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        
        // Create export session with composition
        guard let exportSession = try await createExportSession(
            for: composition,
            outputFormat: format,
            isAudioOnly: true
        ) else {
            throw ConversionError.exportFailed(reason: "Export session failed to complete")
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
            settings: settings
        ) { videoProgress in
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
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(audioBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &dataPointer)
                
                let int16Pointer = UnsafeBufferPointer(
                    start: UnsafeRawPointer(dataPointer)?.assumingMemoryBound(to: Int16.self),
                    count: length / 2
                )
                
                let floatSamples = int16Pointer.map { Float($0) / Float(Int16.max) }
                samples.append(contentsOf: floatSamples)
            }
        }
        
        if samples.isEmpty {
            throw ConversionError.conversionFailed(reason: "No audio samples extracted")
        }
        
        return samples
    }

    private func generateWaveformImage(from samples: [Float], size: CGSize) async throws -> CGImage? {
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        
        guard let context else { return nil }
        
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        let sampleCount = samples.count
        let samplesPerPixel = sampleCount / Int(size.width)
        let midY = size.height / 2
        
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.0)
        
        for x in 0..<Int(size.width) {
            let startSample = x * samplesPerPixel
            let endSample = min(startSample + samplesPerPixel, sampleCount)
            
            if startSample < endSample {
                let sampleSlice = samples[startSample..<endSample]
                let amplitude = sampleSlice.reduce(0) { max($0, abs($1)) }
                let height = amplitude * Float(size.height / 2)
                
                context.move(to: CGPoint(x: CGFloat(x), y: midY - CGFloat(height)))
                context.addLine(to: CGPoint(x: CGFloat(x), y: midY + CGFloat(height)))
                context.strokePath()
            }
        }
        
        return context.makeImage()
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
        
        guard let exportSession = try await createExportSession(
            for: asset,
            outputFormat: format,
            isAudioOnly: true
        ) else {
            throw ConversionError.exportFailed(reason: "Failed to create export session")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        if let audioMix = try await createAudioMix(for: asset) {
            exportSession.audioMix = audioMix
        }
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed(reason: "Export failed: \(String(describing: exportSession.error))")
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "audio",
            suggestedFileName: "converted_audio." + (format.preferredFilenameExtension ?? "m4a"),
            fileType: format,
            metadata: metadata.toDictionary()
        )
    }
    
    func createPixelBuffer(from image: NSImage) throws -> CVPixelBuffer? {
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
        
        if let buffer = try createPixelBuffer(from: image) {
            adaptor.append(buffer, withPresentationTime: .zero)
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
}

