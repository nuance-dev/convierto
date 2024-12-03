import Foundation
import AVFoundation

@available(macOS 14.0, *)
actor MediaConverter {
    enum ConversionError: LocalizedError {
        case exportFailed
        case invalidInput
        case unsupportedFormat
        case conversionFailed
        
        var errorDescription: String? {
            switch self {
            case .exportFailed: return "Failed to export media"
            case .invalidInput: return "Invalid input file"
            case .unsupportedFormat: return "Unsupported format"
            case .conversionFailed: return "Conversion failed"
            }
        }
    }
    
    enum OutputFormat: String, CaseIterable, Identifiable {
        case mp4
        case mov
        case m4v
        case wav
        case m4a
        
        var id: String { rawValue }
        
        var fileType: AVFileType {
            switch self {
            case .mp4: return .mp4
            case .mov: return .mov
            case .m4v: return .m4v
            case .wav: return .wav
            case .m4a: return .m4a
            }
        }
        
        var displayName: String {
            switch self {
            case .mp4: return "MP4"
            case .mov: return "QuickTime Movie"
            case .m4v: return "M4V"
            case .wav: return "WAV Audio"
            case .m4a: return "M4A Audio"
            }
        }
    }
    
    private func monitorProgress(of session: AVAssetExportSession, 
                               handler: @Sendable @escaping (Float) -> Void) async {
        while !Task.isCancelled {
            await MainActor.run {
                handler(session.progress)
            }
            try? await Task.sleep(for: .milliseconds(100))
            
            let status = session.status
            if status == .completed || status == .failed || status == .cancelled {
                break
            }
        }
    }
    
    func convertMedia(
        inputURL: URL,
        outputURL: URL,
        toFormat format: OutputFormat,
        progressHandler: @Sendable @escaping (Float) -> Void
    ) async throws {
        let asset = AVAsset(url: inputURL)
        
        guard try await asset.load(.isPlayable) else {
            throw ConversionError.invalidInput
        }
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ConversionError.exportFailed
        }
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = format.fileType
        exportSession.shouldOptimizeForNetworkUse = true
        
        if let metadata = try? await asset.load(.metadata) {
            exportSession.metadata = metadata
        }
        
        let progressTask = Task {
            await monitorProgress(of: exportSession, handler: progressHandler)
        }
        
        await exportSession.export()
        progressTask.cancel()
        
        switch exportSession.status {
        case .completed:
            return
        case .failed:
            throw exportSession.error ?? ConversionError.exportFailed
        default:
            throw ConversionError.conversionFailed
        }
    }
    
    func getSupportedFormats(for inputURL: URL) async throws -> [OutputFormat] {
        let asset = AVAsset(url: inputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        
        if !tracks.isEmpty {
            return [.mp4, .mov, .m4v]
        }
        
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            return [.m4a, .wav]
        }
        
        throw ConversionError.unsupportedFormat
    }
}
