import AVFoundation
import UniformTypeIdentifiers
import CoreImage
import AppKit

class VideoProcessor: BaseConverter, MediaConverting {
    private let imageProcessor: ImageProcessor
    private let audioVisualizer: AudioVisualizer
    
    override init(settings: ConversionSettings = ConversionSettings()) {
        self.imageProcessor = ImageProcessor(settings: settings)
        self.audioVisualizer = AudioVisualizer(size: CGSize(width: 1920, height: 1080))
        super.init(settings: settings)
    }
    
    func canConvert(from: UTType, to: UTType) -> Bool {
        // Support video to video
        if from.conforms(to: .audiovisualContent) && to.conforms(to: .audiovisualContent) {
            return true
        }
        
        // Support video to audio
        if from.conforms(to: .audiovisualContent) && to.conforms(to: .audio) {
            return true
        }
        
        // Support video to image (frame extraction)
        if from.conforms(to: .audiovisualContent) && to.conforms(to: .image) {
            return true
        }
        
        // Support image to video (animation)
        if from.conforms(to: .image) && to.conforms(to: .audiovisualContent) {
            return true
        }
        
        // Support audio to video (visualization)
        if from.conforms(to: .audio) && to.conforms(to: .audiovisualContent) {
            return true
        }
        
        return false
    }
    
    func convert(_ url: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        let asset = AVAsset(url: url)
        
        guard try await asset.load(.isPlayable) else {
            throw ConversionError.invalidInput
        }
        
        // Handle special conversion cases
        if format.conforms(to: .image) {
            return try await convertVideoToImage(asset: asset, format: format, progress: progress)
        }
        
        if format.conforms(to: .audio) {
            return try await extractAudio(from: asset, to: format, progress: progress)
        }
        
        // Standard video conversion
        let composition = AVMutableComposition()
        
        // Add video track if target format supports video
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
           let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            try compositionVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        }
        
        // Add audio track
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.preferredFilenameExtension ?? "mp4")
        
        guard let exportSession = try await createExportSession(
            for: composition,
            outputFormat: format,
            isAudioOnly: format.conforms(to: .audio)
        ) else {
            throw ConversionError.exportFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        if !format.conforms(to: .audio) {
            exportSession.videoComposition = try await createVideoComposition(for: composition)
        }
        
        // Monitor progress
        let progressTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
        let progressObserver = progressTimer.sink { _ in
            progress.completedUnitCount = Int64(exportSession.progress * 100)
        }
        
        defer {
            progressObserver.cancel()
        }
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw exportSession.error ?? ConversionError.exportFailed
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: url.lastPathComponent,
            suggestedFileName: url.deletingPathExtension().lastPathComponent + "." + (format.preferredFilenameExtension ?? "mp4"),
            fileType: format
        )
    }
    
    private func convertVideoToImage(asset: AVAsset, format: UTType, progress: Progress) async throws -> ProcessingResult {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        // Extract frame at 1/3 of the video duration for a good thumbnail
        let duration = try await asset.load(.duration)
        let time = CMTime(seconds: duration.seconds / 3, preferredTimescale: 600)
        
        let cgImage = try await generator.image(at: time).image
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.preferredFilenameExtension ?? "jpg")
        
        // Convert NSImage to proper format and save
        try await imageProcessor.saveImage(nsImage, format: format, to: outputURL)
        
        progress.completedUnitCount = 100
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "frame.jpg",
            suggestedFileName: "video_frame." + (format.preferredFilenameExtension ?? "jpg"),
            fileType: format
        )
    }
    
    private func extractAudio(from asset: AVAsset, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        let composition = AVMutableComposition()
        
        // Extract audio tracks
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ConversionError.invalidInput
        }
        
        let timeRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        try compositionAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.preferredFilenameExtension ?? "m4a")
        
        guard let exportSession = try await createExportSession(
            for: composition,
            outputFormat: format,
            isAudioOnly: true
        ) else {
            throw ConversionError.exportFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw exportSession.error ?? ConversionError.exportFailed
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "audio.m4a",
            suggestedFileName: "extracted_audio." + (format.preferredFilenameExtension ?? "m4a"),
            fileType: format
        )
    }
    
    private func createVideoComposition(for composition: AVComposition) async throws -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        if let videoTrack = try? await composition.loadTracks(withMediaType: .video).first {
            let size = try? await videoTrack.load(.naturalSize)
            videoComposition.renderSize = size ?? CGSize(width: 1920, height: 1080)
            
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
            
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            instruction.layerInstructions = [layerInstruction]
            
            videoComposition.instructions = [instruction]
        }
        
        return videoComposition
    }
    
    private func createVideoFromImage(_ image: NSImage) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        
        let videoWriter = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(image.size.width),
            AVVideoHeightKey: Int(image.size.height)
        ]
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)
            ]
        )
        
        videoWriter.add(videoInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        
        // Convert NSImage to CGImage
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.conversionFailed
        }
        
        // Create pixel buffer
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(image.size.width),
            Int(image.size.height),
            kCVPixelFormatType_32ARGB,
            nil,
            &pixelBuffer
        )
        
        guard let buffer = pixelBuffer else {
            throw ConversionError.conversionFailed
        }
        
        // Render image to pixel buffer
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(image.size.width),
            height: Int(image.size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        
        // Write frames
        adaptor.append(buffer, withPresentationTime: .zero)
        videoInput.markAsFinished()
        await videoWriter.finishWriting()
        
        return outputURL
    }
}