import AVFoundation
import UniformTypeIdentifiers
import CoreImage
import AppKit

protocol ResourceManaging {
    func cleanup()
}

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
        let asset = AVURLAsset(url: url)
        
        return try await withThrowingTaskGroup(of: ProcessingResult.self) { group in
            group.addTask {
                return try await self.performConversion(asset: asset, to: format, progress: progress, originalURL: url)
            }
            
            guard let result = try await group.next() else {
                throw ConversionError.conversionFailed
            }
            
            return result
        }
    }
    
    private func performConversion(
        asset: AVAsset,
        to format: UTType,
        progress: Progress,
        originalURL: URL
    ) async throws -> ProcessingResult {
        let outputURL = try CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
        
        guard let exportSession = try await createExportSession(for: asset, outputFormat: format) else {
            throw ConversionError.conversionFailed
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        let progressTask = Task {
            while !Task.isCancelled {
                progress.completedUnitCount = Int64(exportSession.progress * 100)
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                if exportSession.status == .completed || exportSession.status == .failed {
                    break
                }
            }
        }
        
        await exportSession.export()
        progressTask.cancel()
        
        guard exportSession.status == .completed else {
            throw exportSession.error ?? ConversionError.conversionFailed
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: originalURL.lastPathComponent,
            suggestedFileName: "converted_video." + (format.preferredFilenameExtension ?? "mp4"),
            fileType: format
        )
    }
}
