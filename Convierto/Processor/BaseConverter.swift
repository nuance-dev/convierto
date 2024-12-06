import Foundation
import AVFoundation
import UniformTypeIdentifiers
import os

protocol MediaConverting {
    func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult
    func canConvert(from: UTType, to: UTType) -> Bool
    var settings: ConversionSettings { get }
    func validateConversion(from: UTType, to: UTType) throws -> ConversionStrategy
}

class BaseConverter: MediaConverting {
    let settings: ConversionSettings
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "BaseConverter")
    
    required init(settings: ConversionSettings = ConversionSettings()) {
        self.settings = settings
    }
    
    func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        throw ConversionError.conversionFailed(reason: "Base converter cannot perform conversions")
    }
    
    func canConvert(from: UTType, to: UTType) -> Bool {
        return false // Base implementation returns false, subclasses should override
    }
    
    func getAVFileType(for format: UTType) -> AVFileType {
        switch format {
        case .mpeg4Movie:
            return .mp4
        case .quickTimeMovie:
            return .mov
        case .mp3:
            return .mp3
        case .wav:
            return .wav
        case .m4a, .aac, .mpeg4Audio:
            return .m4a
        default:
            return .mp4
        }
    }
    
    func createExportSession(
        for asset: AVAsset,
        outputFormat: UTType,
        isAudioOnly: Bool = false
    ) async throws -> AVAssetExportSession? {
        return AVAssetExportSession(
            asset: asset,
            presetName: isAudioOnly ? AVAssetExportPresetAppleM4A : settings.videoQuality
        )
    }
    
    func createAudioMix(for asset: AVAsset) async throws -> AVAudioMix? {
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        
        let audioMix = AVMutableAudioMix()
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        
        parameters.audioTimePitchAlgorithm = .spectral
        parameters.setVolumeRamp(fromStartVolume: 1.0, 
                               toEndVolume: 1.0, 
                               timeRange: CMTimeRange(start: .zero, 
                                                    duration: try await asset.load(.duration)))
        
        audioMix.inputParameters = [parameters]
        return audioMix
    }
    
    func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // Add the main operation
            group.addTask {
                try await operation()
            }
            
            // Add timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ConversionError.timeout(duration: seconds)
            }
            
            // Get first completed result
            guard let result = try await group.next() else {
                throw ConversionError.timeout(duration: seconds)
            }
            
            // Cancel remaining tasks
            group.cancelAll()
            return result
        }
    }
    
    func validateConversion(from inputType: UTType, to outputType: UTType) throws -> ConversionStrategy {
        // Check basic compatibility
        guard canConvert(from: inputType, to: outputType) else {
            throw ConversionError.incompatibleFormats(from: inputType, to: outputType)
        }
        
        // Determine conversion strategy
        let strategy: ConversionStrategy
        
        switch (inputType, outputType) {
        case (let i, let o) where i.conforms(to: .image) && o.conforms(to: .audiovisualContent):
            strategy = .createVideo
            
        case (let i, let o) where i.conforms(to: .audio) && o.conforms(to: .image):
            strategy = .visualize
            
        case (let i, let o) where i.conforms(to: .audiovisualContent) && o.conforms(to: .image):
            strategy = .extractFrame
            
        case (let i, let o) where i.conforms(to: .audio) && o.conforms(to: .audiovisualContent):
            strategy = .visualize
            
        case (let i, let o) where i.conforms(to: .image) && o == .pdf:
            strategy = .combine
            
        case (.pdf, let o) where o.conforms(to: .image):
            strategy = .extractFrame
            
        default:
            strategy = .direct
        }
        
        return strategy
    }
    
    func validateConversionCapabilities(from inputType: UTType, to outputType: UTType) throws {
        // Check system resources
        let availableMemory = ProcessInfo.processInfo.physicalMemory
        let requiredMemory = estimateMemoryRequirement(for: inputType, to: outputType)
        
        if requiredMemory > availableMemory / 2 {
            throw ConversionError.insufficientMemory(
                required: requiredMemory,
                available: availableMemory
            )
        }
        
        // Validate format compatibility
        guard let strategy = try? validateConversion(from: inputType, to: outputType) else {
            throw ConversionError.incompatibleFormats(from: inputType, to: outputType)
        }
        
        // Check if conversion is actually possible
        if !canActuallyConvert(from: inputType, to: outputType, strategy: strategy) {
            throw ConversionError.conversionNotPossible(
                reason: "No suitable conversion path available from \(inputType.localizedDescription ?? "unknown") to \(outputType.localizedDescription ?? "unknown")"
            )
        }
    }
    
    private func canActuallyConvert(from inputType: UTType, to outputType: UTType, strategy: ConversionStrategy) -> Bool {
        switch (inputType, outputType) {
        case (let i, let o) where i.conforms(to: .image) && o.conforms(to: .audiovisualContent):
            return true // Image to video is always possible
        case (let i, let o) where i.conforms(to: .audio) && o.conforms(to: .image):
            return true // Audio visualization is always possible
        case (let i, let o) where i.conforms(to: .audiovisualContent) && o.conforms(to: .image):
            return true // Frame extraction is always possible
        case (let i, let o) where i.conforms(to: .image) && o == .pdf:
            return true // Image to PDF is always possible
        case (.pdf, let o) where o.conforms(to: .image):
            return true // PDF to image is always possible
        default:
            return strategy == .direct // For other cases, only direct conversion is reliable
        }
    }
    
    private func estimateMemoryRequirement(for inputType: UTType, to outputType: UTType) -> UInt64 {
        // Base memory requirement
        var requirement: UInt64 = 100_000_000 // 100MB base
        
        // Add memory based on conversion type
        if inputType.conforms(to: .audiovisualContent) || outputType.conforms(to: .audiovisualContent) {
            requirement += 500_000_000 // +500MB for video processing
        }
        
        if inputType.conforms(to: .image) && outputType.conforms(to: .audiovisualContent) {
            requirement += 250_000_000 // +250MB for image-to-video
        }
        
        return requirement
    }
}
