import AVFoundation

class AudioProcessor {
    func convert(_ url: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        let asset = AVAsset(url: url)
        
        guard try await asset.load(.isPlayable) else {
            throw ConversionError.invalidInput
        }
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ConversionError.exportFailed
        }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.preferredFilenameExtension ?? "m4a")
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = AVFileType(rawValue: format.identifier)
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw exportSession.error ?? ConversionError.exportFailed
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: url.lastPathComponent,
            suggestedFileName: url.deletingPathExtension().lastPathComponent + "." + (format.preferredFilenameExtension ?? "converted"),
            fileType: format
        )
    }
}