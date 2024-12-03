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
    
    private func monitorProgress(of session: SendableExportSession, 
                               handler: @Sendable @escaping (Float) -> Void) async {
        while !Task.isCancelled {
            let progress = await session.progress
            await MainActor.run {
                handler(progress)
            }
            try? await Task.sleep(for: .milliseconds(100))
            
            let status = await session.status
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
        
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ConversionError.exportFailed
        }
        
        let sendableSession = SendableExportSession(exportSession)
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = format.fileType
        exportSession.shouldOptimizeForNetworkUse = true
        
        let progressTask = Task {
            await monitorProgress(of: sendableSession, handler: progressHandler)
        }
        
        try await sendableSession.export()
        progressTask.cancel()
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
