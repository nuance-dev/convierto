import Foundation
import AVFoundation

@available(macOS 12.0, *)
actor VideoProcessor {
    enum VideoError: LocalizedError {
        case exportFailed
        case invalidInput
        case compressionFailed
        
        var errorDescription: String? {
            switch self {
            case .exportFailed: return "Failed to export video"
            case .invalidInput: return "Invalid input video"
            case .compressionFailed: return "Video compression failed"
            }
        }
    }
    
    struct VideoCompressionSettings: Sendable {
        let quality: Float
        let maxWidth: Int?
        let bitrateMultiplier: Float
        let frameRate: Int?
        let audioEnabled: Bool
        
        init(
            quality: Float = 0.7,
            maxWidth: Int? = nil,
            bitrateMultiplier: Float = 0.7,
            frameRate: Int? = 30,
            audioEnabled: Bool = true
        ) {
            self.quality = quality
            self.maxWidth = maxWidth
            self.bitrateMultiplier = bitrateMultiplier
            self.frameRate = frameRate
            self.audioEnabled = audioEnabled
        }
    }
    
    func compressVideo(
        inputURL: URL,
        outputURL: URL,
        settings: VideoCompressionSettings,
        progressHandler: @Sendable @escaping (Float) -> Void
    ) async throws {
        let asset = AVAsset(url: inputURL)
        
        // Get video track
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.invalidInput
        }
        
        // Get original dimensions and apply size limit if needed
        let originalSize = try await videoTrack.load(.naturalSize)
        var targetSize = originalSize
        
        if let maxWidth = settings.maxWidth {
            let scale = Float(maxWidth) / Float(originalSize.width)
            if scale < 1.0 {
                targetSize = CGSize(
                    width: CGFloat(maxWidth),
                    height: CGFloat(Float(originalSize.height) * scale)
                )
            }
        }
        
        // Get original frame rate
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let targetFrameRate = Float(settings.frameRate ?? Int(nominalFrameRate))
        
        // Create export session
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw VideoError.exportFailed
        }
        
        // Calculate bitrate
        let originalBitrate = try await estimateBitrate(for: videoTrack)
        let targetBitrate = Int(Float(originalBitrate) * settings.bitrateMultiplier)
        
        // Configure compression
        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: targetBitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC
        ]
        
        // Video settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(targetSize.width),
            AVVideoHeightKey: Int(targetSize.height),
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        
        // Create and configure video composition
        let composition = AVMutableVideoComposition()
        composition.renderSize = targetSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFrameRate))
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: try await asset.load(.duration)
        )
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        
        // Calculate transform for proper resizing
        let originalTransform = try await videoTrack.load(.preferredTransform)
        var finalTransform = originalTransform
        
        let scaleX = targetSize.width / originalSize.width
        let scaleY = targetSize.height / originalSize.height
        
        // Apply scaling transform
        finalTransform = finalTransform.concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        layerInstruction.setTransform(finalTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        
        // Configure export session
        exportSession.videoComposition = composition
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        
        // Use Task for progress monitoring
        let progressTask = Task { @MainActor in
            repeat {
                progressHandler(exportSession.progress)
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            } while exportSession.status == .exporting
        }
        
        // Start export and wait for completion
        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                progressTask.cancel() // Stop progress monitoring
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    let error = exportSession.error ?? VideoError.exportFailed
                    continuation.resume(throwing: error)
                default:
                    continuation.resume(throwing: VideoError.compressionFailed)
                }
            }
        }
    }
    
    private func estimateBitrate(for videoTrack: AVAssetTrack) async throws -> Int {
        let duration = try await videoTrack.load(.timeRange).duration.seconds
        let size = try await videoTrack.load(.totalSampleDataLength)
        return Int(Double(size) * 8 / duration) // bits per second
    }
}
