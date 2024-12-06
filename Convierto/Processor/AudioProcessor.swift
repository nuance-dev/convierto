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
    private let maxBufferSize: Int = 1024 * 1024 // 1MB buffer size
    
    required init(settings: ConversionSettings = ConversionSettings()) {
        self.resourcePool = ResourcePool.shared
        self.visualizer = AudioVisualizer(size: CGSize(width: 1920, height: 1080))
        self.imageProcessor = ImageProcessor(settings: settings)
        super.init(settings: settings)
    }
    
    override func canConvert(from: UTType, to: UTType) -> Bool {
        switch (from, to) {
        case (let f, _) where f.conforms(to: .audio):
            return to.conforms(to: .audio) || 
                   to.conforms(to: .audiovisualContent) || 
                   to.conforms(to: .image)
        case (_, let t) where t.conforms(to: .audiovisualContent):
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
        logger.debug("Creating visualized video")
        
        let duration = try await asset.load(.duration)
        let frameCount = Int(duration.seconds * Double(settings.frameRate))
        
        // Create video composition
        let composition = AVMutableComposition()
        
        // Add audio track with proper settings
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: audioTrack,
                at: .zero
            )
        }
        
        // Generate visualization frames
        progress.totalUnitCount = Int64(frameCount)
        let frames = try await visualizer.generateVisualizationFrames(
            for: asset,
            frameCount: frameCount
        )
        
        // Create video track from frames
        let videoTrack = try await visualizer.createVideoTrack(
            from: frames,
            duration: duration,
            settings: settings
        )
        
        // Add video track to composition
        if let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) {
            try compositionVideoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: videoTrack,
                at: .zero
            )
        }
        
        // Export with proper settings
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: settings.videoQuality
        ) else {
            throw ConversionError.exportFailed(reason: "Export session failed to complete")
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = format == .quickTimeMovie ? .mov : .mp4
        
        // Monitor export progress using async/await
        let progressTask = Task {
            while !Task.isCancelled {
                progress.completedUnitCount = Int64(exportSession.progress * 100)
                if exportSession.status == .completed || exportSession.status == .failed {
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            }
        }
        
        await exportSession.export()
        progressTask.cancel()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed(reason: "Export session failed to complete")
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "audio_visualization",
            suggestedFileName: "visualized_audio." + (format.preferredFilenameExtension ?? "mp4"),
            fileType: format,
            metadata: metadata.toDictionary()
        )
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
    
    private func extractAudioSamples(from asset: AVAsset) async throws -> [Float] {
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
}
