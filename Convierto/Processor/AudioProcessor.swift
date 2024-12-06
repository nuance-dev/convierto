import AVFoundation
import CoreGraphics
import AppKit
import UniformTypeIdentifiers
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
    category: "AudioProcessor"
)

class AudioProcessor: BaseConverter, MediaConverting {
    private let visualizer: AudioVisualizer
    private let imageProcessor: ImageProcessor
    
    override init(settings: ConversionSettings = ConversionSettings()) {
        self.visualizer = AudioVisualizer(size: CGSize(width: 1920, height: 1080))
        self.imageProcessor = ImageProcessor(settings: settings)
        super.init(settings: settings)
    }
    
    func canConvert(from: UTType, to: UTType) -> Bool {
        if from.conforms(to: .audio) {
            return to.conforms(to: .audio) ||
                   to.conforms(to: .audiovisualContent) ||
                   to.conforms(to: .image)
        }
        return false
    }
    
    func convert(_ url: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        let asset = AVAsset(url: url)
        progress.totalUnitCount = 100
        
        guard try await asset.loadTracks(withMediaType: .audio).first != nil else {
            throw ConversionError.invalidInput
        }
        
        let outputURL = try CacheManager.shared.createTemporaryURL(
            for: format.preferredFilenameExtension ?? "m4a"
        )
        
        if format.conforms(to: .audiovisualContent) {
            return try await createVisualizedVideo(from: asset, to: outputURL, format: format, progress: progress)
        } else if format.conforms(to: .image) {
            return try await createWaveformImage(from: asset, to: outputURL, format: format, progress: progress)
        } else {
            return try await convertAudioFormat(from: asset, to: outputURL, format: format, progress: progress)
        }
    }
    
    private func convertAudioFormat(
        from asset: AVAsset,
        to outputURL: URL,
        format: UTType,
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
            throw ConversionError.conversionFailed
        }
        
        let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        
        // Create export session with composition
        guard let exportSession = try await createExportSession(
            for: composition,
            outputFormat: format,
            isAudioOnly: true
        ) else {
            throw ConversionError.exportFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        // Apply audio mix if needed
        if let audioMix = try await createAudioMix(for: composition) {
            exportSession.audioMix = audioMix
        }
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw ConversionError.exportFailed
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "audio",
            suggestedFileName: "converted_audio." + (format.preferredFilenameExtension ?? "m4a"),
            fileType: format
        )
    }
    
    private func createVisualizedVideo(
        from asset: AVAsset,
        to outputURL: URL,
        format: UTType,
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
            throw ConversionError.exportFailed
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
            throw ConversionError.exportFailed
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "audio_visualization",
            suggestedFileName: "visualized_audio." + (format.preferredFilenameExtension ?? "mp4"),
            fileType: format
        )
    }
    
    private func createWaveformImage(
        from asset: AVAsset,
        to outputURL: URL,
        format: UTType,
        progress: Progress
    ) async throws -> ProcessingResult {
        logger.debug("Creating waveform image")
        
        let waveformImage = try await visualizer.generateWaveformImage(for: asset, size: visualizer.size)
        let nsImage = NSImage(cgImage: waveformImage, size: visualizer.size)
        
        try await imageProcessor.saveImage(
            nsImage,
            format: format,
            to: outputURL
        )
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "waveform",
            suggestedFileName: "waveform." + (format.preferredFilenameExtension ?? "png"),
            fileType: format
        )
    }
    
    func validateConversion(from inputType: UTType, to outputType: UTType) throws -> ConversionStrategy {
        guard canConvert(from: inputType, to: outputType) else {
            throw ConversionError.incompatibleFormats
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
        
        throw ConversionError.incompatibleFormats
    }
}
