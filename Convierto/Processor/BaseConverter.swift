import Foundation
import AVFoundation
import UniformTypeIdentifiers
import os
import CoreImage
import AppKit

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
        logger.debug("🔍 Validating conversion from \(inputType.identifier) to \(outputType.identifier)")
        
        // Ensure types are actually different
        if inputType == outputType {
            logger.debug("⚠️ Same input and output format detected")
            return .direct
        }
        
        // Validate basic compatibility
        guard canConvert(from: inputType, to: outputType) else {
            logger.error("❌ Incompatible formats detected")
            throw ConversionError.incompatibleFormats(from: inputType, to: outputType)
        }
        
        logger.debug("✅ Format validation successful")
        return .direct
    }
    
    func validateConversionCapabilities(from inputType: UTType, to outputType: UTType) throws {
        logger.debug("Validating conversion capabilities from \(inputType.identifier) to \(outputType.identifier)")
        
        // Check system resources
        let availableMemory = ProcessInfo.processInfo.physicalMemory
        let requiredMemory = estimateMemoryRequirement(for: inputType, to: outputType)
        
        logger.debug("Memory check - Required: \(String(describing: requiredMemory)), Available: \(String(describing: availableMemory))")
        
        if requiredMemory > availableMemory / 2 {
            logger.error("Insufficient memory for conversion")
            throw ConversionError.insufficientMemory(
                required: requiredMemory,
                available: availableMemory
            )
        }
        
        // Validate format compatibility
        let strategy: ConversionStrategy
        do {
            strategy = try validateConversion(from: inputType, to: outputType)
        } catch {
            logger.error("Format compatibility validation failed: \(error.localizedDescription)")
            throw error
        }
        
        logger.debug("Conversion strategy determined: \(String(describing: strategy))")
        
        // Check if conversion is actually possible
        if !canActuallyConvert(from: inputType, to: outputType, strategy: strategy) {
            logger.error("Conversion not possible with current configuration")
            throw ConversionError.conversionNotPossible(
                reason: "Cannot convert from \(inputType.identifier) to \(outputType.identifier) using strategy \(String(describing: strategy))"
            )
        }
        
        logger.debug("Conversion capabilities validation successful")
    }
    
    func canActuallyConvert(from inputType: UTType, to outputType: UTType, strategy: ConversionStrategy) -> Bool {
        logger.debug("Checking actual conversion possibility for strategy: \(String(describing: strategy))")
        
        // Verify system capabilities
        let hasRequiredFrameworks: Bool = verifyFrameworkAvailability(for: strategy)
        let hasRequiredPermissions: Bool = verifyPermissions(for: strategy)
        
        logger.debug("Frameworks available: \(String(describing: hasRequiredFrameworks))")
        logger.debug("Permissions verified: \(String(describing: hasRequiredPermissions))")
        
        return hasRequiredFrameworks && hasRequiredPermissions
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
    
    private func verifyFrameworkAvailability(for strategy: ConversionStrategy) -> Bool {
        switch strategy {
        case .createVideo:
            if #available(macOS 13.0, *) {
                let session = AVAssetExportSession(asset: AVAsset(), presetName: AVAssetExportPresetHighestQuality)
                return session?.supportedFileTypes.contains(.mp4) ?? false
            } else {
                return AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHighestQuality)
            }
            
        case .extractFrame:
            return NSImage.self != nil
            
        case .visualize:
            #if canImport(CoreImage)
            return CIContext(options: [CIContextOption.useSoftwareRenderer: false]) != nil
            #else
            return false
            #endif
            
        case .extractAudio:
            if #available(macOS 13.0, *) {
                let session = AVAssetExportSession(asset: AVAsset(), presetName: AVAssetExportPresetAppleM4A)
                return session?.supportedFileTypes.contains(.m4a) ?? false
            } else {
                return AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetAppleM4A)
            }
            
        case .combine:
            return NSGraphicsContext.self != nil
            
        case .direct:
            return true
        }
    }
    
    private func verifyPermissions(for strategy: ConversionStrategy) -> Bool {
        switch strategy {
        case .createVideo, .extractFrame, .visualize:
            return true // No special permissions needed for media processing
        case .extractAudio:
            return true // Audio processing doesn't require special permissions
        case .combine:
            return true // Document processing doesn't require special permissions
        case .direct:
            return true // Basic conversion doesn't require special permissions
        }
    }
}
