import AVFoundation

class VideoProcessor {
    func convert(_ url: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        let asset = AVAsset(url: url)
        
        // Validate video track
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.invalidInput
        }
        
        let composition = AVMutableComposition()
        guard let videoCompositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ConversionError.conversionFailed
        }
        
        // Insert video track
        try videoCompositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: try await asset.load(.duration)),
            of: videoTrack,
            at: .zero
        )
        
        // Handle audio if present
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
           let audioCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audioCompositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: try await asset.load(.duration)),
                of: audioTrack,
                at: .zero
            )
        }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.preferredFilenameExtension ?? "mp4")
        
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ConversionError.conversionFailed
        }
        
        export.outputURL = outputURL
        export.outputFileType = AVFileType(rawValue: format.identifier)
        
        // Monitor progress
        let progressTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
        let progressObserver = progressTimer.sink { _ in
            progress.completedUnitCount = Int64(export.progress * 100)
        }
        
        let exportTask = Task {
            await export.export()
            guard export.status == .completed else {
                throw export.error ?? ConversionError.exportFailed
            }
        }
        
        try await exportTask.value
        progressObserver.cancel()
        
        progress.completedUnitCount = 100
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: url.lastPathComponent,
            suggestedFileName: url.deletingPathExtension().lastPathComponent + "." + (format.preferredFilenameExtension ?? "converted"),
            fileType: format
        )
    }
}