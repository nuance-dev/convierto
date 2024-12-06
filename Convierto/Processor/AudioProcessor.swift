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
        logger.debug("🎵 Starting audio conversion process")
        logger.debug("📂 Input file: \(url.path)")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        let taskId = UUID()
        logger.debug("🔑 Task ID: \(taskId.uuidString)")
        
        await resourcePool.beginTask(id: taskId, type: .audio)
        defer { Task { await resourcePool.endTask(id: taskId) } }
        
        do {
            let asset = AVAsset(url: url)
            logger.debug("📼 Asset created successfully")
            
            try await validateAudioAsset(asset)
            logger.debug("✅ Asset validation passed")
            
            try await resourcePool.checkResourceAvailability(taskId: taskId, type: .audio)
            logger.debug("✅ Resource availability confirmed")
            
            let strategy = try determineConversionStrategy(from: asset, to: format)
            logger.debug("⚙️ Conversion strategy determined: \(String(describing: strategy))")
            
            let outputURL = try await CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
            logger.debug("📝 Output URL created: \(outputURL.path)")
            
            // Check if task was cancelled
            if Task.isCancelled {
                throw ConversionError.cancelled
            }
            
            return try await withTimeout(seconds: 300) {
                logger.debug("⏳ Starting conversion with 300s timeout")
                let result = try await self.executeConversion(
                    asset: asset,
                    to: outputURL,
                    format: format,
                    strategy: strategy,
                    progress: progress,
                    metadata: metadata
                )
                logger.debug("✅ Conversion completed successfully")
                return result
            }
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
        
        // Configure progress tracking
        progress.totalUnitCount = 100
        progress.completedUnitCount = 0
        
        let duration = try await asset.load(.duration)
        let fps = 30
        let totalFrames = min(Int(duration.seconds * Double(fps)), 1800)
        
        logger.debug("⚙️ Generating \(totalFrames) frames for \(duration.seconds) seconds")
        
        // Generate frames with progress tracking
        let frames = try await visualizer.generateVisualizationFrames(
            for: asset,
            frameCount: totalFrames
        ) { [weak self] frameProgress in
            progress.completedUnitCount = Int64(frameProgress * 50)
            
            Task { @MainActor in
                self?.progressTracker.updateProgress(for: "visualization", progress: frameProgress)
                self?.progressTracker.setStage(.processing, message: "Generating visualization frames...")
            }
        }
        
        progress.completedUnitCount = 50
        
        await MainActor.run {
            progressTracker.setStage(.optimizing, message: "Creating video track...")
        }
        
        // Create video track
        let videoTrack = try await visualizer.createVideoTrack(
            from: frames,
            duration: duration,
            settings: settings
        )
        
        progress.completedUnitCount = 75
        
        await MainActor.run {
            progressTracker.setStage(.exporting, message: "Finalizing video...")
        }
        
        return ProcessingResult(
            outputURL: outputURL,
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
