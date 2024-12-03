import Foundation
import AVFoundation
import UniformTypeIdentifiers

@available(macOS 14.0, *)
actor MediaConverter: @unchecked Sendable {
    private let supportedInputFormats = Set<UTType>([
        .mpeg4Movie, .quickTimeMovie, .avi,
        .mp3, .wav, .aiff, .mpeg4Audio
    ])
    
    private let supportedOutputFormats = Set<UTType>([
        .mpeg4Movie, .quickTimeMovie,
        .mp3, .wav,
        UTType("public.mpeg-4"),
        UTType("public.mp4"),
        UTType("public.m4a")
    ].compactMap { $0 })
    
    func convertMedia(
        inputURL: URL,
        outputURL: URL,
        toFormat format: UTType,
        progressHandler: @Sendable @escaping (Float) -> Void
    ) async throws {
        guard let session = try await createExportSession(for: inputURL, outputFormat: format) else {
            throw ConversionError.exportFailed
        }
        
        // Configure export
        session.outputURL = outputURL
        session.outputFileType = AVFileType(rawValue: format.identifier)
        session.shouldOptimizeForNetworkUse = true
        
        // Monitor progress with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    await MainActor.run {
                        progressHandler(session.progress)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    
                    if session.status == .completed {
                        break
                    }
                }
            }
            
            group.addTask {
                await session.export()
                guard session.status == .completed else {
                    throw session.error ?? ConversionError.exportFailed
                }
            }
            
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw ConversionError.conversionTimeout
            }
            
            try await group.next()
            group.cancelAll()
        }
        
        // Verify output
        guard FileManager.default.fileExists(atPath: outputURL.path),
              let outputSize = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              outputSize > 0 else {
            throw ConversionError.exportFailed
        }
    }
    
    private func createExportSession(for url: URL, outputFormat: UTType) async throws -> AVAssetExportSession? {
        let asset = AVAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw ConversionError.invalidInput
        }
        
        return AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        )
    }
    
    func isFormatSupported(_ format: UTType) -> Bool {
        supportedOutputFormats.contains(format)
    }
    
    func canConvert(from inputFormat: UTType, to outputFormat: UTType) -> Bool {
        supportedInputFormats.contains(where: { inputFormat.conforms(to: $0) }) &&
        supportedOutputFormats.contains(outputFormat)
    }
}
