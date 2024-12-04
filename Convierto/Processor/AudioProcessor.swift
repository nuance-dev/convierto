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
        let frames = try await visualizer.generateVisualizationFrames(for: asset, frameCount: frameCount)
        
        // Create video track from visualization frames
        let videoTrack = try await visualizer.createVideoTrack(from: frames, duration: duration)
        
        // Create final composition
        let composition = AVMutableComposition()
        
        // Add video track
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
        
        // Add audio track
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
        
        // Export final video
        guard let exportSession = try await createExportSession(
            for: composition,
            outputFormat: format,
            isAudioOnly: false
        ) else {
            throw ConversionError.exportFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        await exportSession.export()
        
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
}
