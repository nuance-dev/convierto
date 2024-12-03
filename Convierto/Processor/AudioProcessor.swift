import AVFoundation

class AudioProcessor {
    func convert(_ url: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        let asset = AVAsset(url: url)
        let composition = AVMutableComposition()
        
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.invalidInput
        }
        
        let audioCompositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        
        try audioCompositionTrack?.insertTimeRange(
            CMTimeRange(start: .zero, duration: try await asset.load(.duration)),
            of: audioTrack,
            at: .zero
        )
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.preferredFilenameExtension ?? "m4a")
        
        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ConversionError.conversionFailed
        }
        
        export.outputURL = outputURL
        export.outputFileType = .init(rawValue: format.identifier)
        
        try await export.export()
        
        if export.status != .completed {
            throw ConversionError.exportFailed
        }
        
        progress.completedUnitCount = 100
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: url.lastPathComponent,
            suggestedFileName: url.deletingPathExtension().lastPathComponent + "." + (format.preferredFilenameExtension ?? ""),
            fileType: format
        )
    }
}