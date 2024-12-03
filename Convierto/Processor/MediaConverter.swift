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
    
    func convertMedia(
        inputURL: URL,
        outputURL: URL,
        toFormat format: OutputFormat,
        progressHandler: @Sendable @escaping (Float) -> Void
    ) async throws {
        let asset = AVAsset(url: inputURL)
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ConversionError.exportFailed
        }
        
        // Configure export session
        exportSession.outputURL = outputURL
        exportSession.outputFileType = format.fileType
        
        // Use Task for progress monitoring
        let progressMonitor = Task.detached { [weak exportSession] in
            guard let session = exportSession else { return }
            repeat {
                await progressHandler(session.progress)
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            } while await session.status == .exporting
        }
        
        // Start export and wait for completion
        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously { [weak exportSession] in
                guard let session = exportSession else {
                    continuation.resume(throwing: ConversionError.exportFailed)
                    return
                }
                progressMonitor.cancel() // Stop progress monitoring
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    let error = session.error ?? ConversionError.exportFailed
                    continuation.resume(throwing: error)
                default:
                    continuation.resume(throwing: ConversionError.conversionFailed)
                }
            }
        }
    }
    
    func getSupportedFormats(for inputURL: URL) async throws -> [OutputFormat] {
        let asset = AVAsset(url: inputURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        
        // If it has video tracks, return video formats
        if !tracks.isEmpty {
            return [.mp4, .mov, .m4v]
        }
        
        // Check for audio-only content
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            return [.m4a, .wav]
        }
        
        throw ConversionError.unsupportedFormat
    }
}
