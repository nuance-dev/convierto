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
    
    // Memory requirements in bytes for different conversion types
    private struct MemoryRequirements {
        static let base: UInt64 = 100_000_000 // 100MB
        static let videoProcessing: UInt64 = 500_000_000 // 500MB
        static let imageToVideo: UInt64 = 250_000_000 // 250MB
    }
    
    required init(settings: ConversionSettings = ConversionSettings()) throws {
        self.settings = settings
        
        // Validate settings
        guard settings.videoBitRate > 0 else {
            throw ConversionError.invalidConfiguration("Video bitrate must be positive")
        }
        guard settings.audioBitRate > 0 else {
            throw ConversionError.invalidConfiguration("Audio bitrate must be positive")
        }
        
        logger.debug("Initialized BaseConverter with settings: \(String(describing: settings))")
    }
    
    /// Base implementation - must be overridden by subclasses
    func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        fatalError("convert(_:to:metadata:progress:) must be overridden by subclass")
    }
    
    /// Base implementation - must be overridden by subclasses
    func canConvert(from: UTType, to: UTType) -> Bool {
        fatalError("canConvert(from:to:) must be overridden by subclass")
    }
    
    func getAVFileType(for format: UTType) -> AVFileType {
        logger.debug("Determining AVFileType for format: \(format.identifier)")
        
        switch format {
        case _ where format == .mp3:
            return .mp3
        case _ where format == .wav || format.identifier == "com.microsoft.waveform-audio":
            return .wav
        case _ where format == .m4a || format.identifier == "public.mpeg-4-audio":
            return .m4a
        case _ where format == .aac:
            return .m4a  // AAC is typically contained in M4A
        case _ where format.conforms(to: .audio):
            logger.debug("⚠️ Generic audio format, defaulting to M4A")
            return .m4a
        default:
            logger.debug("⚠️ Unknown format, defaulting to MP4: \(format.identifier)")
            return .mp4
        }
    }
    
    func createExportSession(
        for asset: AVAsset,
        outputFormat: UTType,
        isAudioOnly: Bool = false
    ) async throws -> AVAssetExportSession {
        let presetName = isAudioOnly ? AVAssetExportPresetAppleM4A : settings.videoQuality
        logger.debug("Creating export session with preset: \(presetName)")
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            logger.error("Failed to create export session with preset: \(presetName)")
            throw ConversionError.conversionFailed(reason: "Failed to create export session with preset: \(presetName)")
        }
        
        // Validate supported file types
        guard exportSession.supportedFileTypes.contains(getAVFileType(for: outputFormat)) else {
            logger.error("Export session doesn't support output format: \(outputFormat.identifier)")
            throw ConversionError.unsupportedFormat(format: outputFormat)
        }
        
        return exportSession
    }
    
    func createAudioMix(for asset: AVAsset) async throws -> AVAudioMix? {
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            logger.debug("No audio track found in asset")
            return nil
        }
        
        logger.debug("Creating audio mix for track: \(audioTrack)")
        
        let audioMix = AVMutableAudioMix()
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        
        // Configure audio parameters based on settings
        parameters.audioTimePitchAlgorithm = .spectral
        let duration = try await asset.load(.duration)
        
        parameters.setVolumeRamp(
            fromStartVolume: settings.audioStartVolume,
            toEndVolume: settings.audioEndVolume,
            timeRange: CMTimeRange(start: .zero, duration: duration)
        )
        
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
            }
            return AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHighestQuality)
            
        case .visualize:
            #if canImport(CoreImage)
            return CIContext(options: [CIContextOption.useSoftwareRenderer: false]) != nil
            #else
            return false
            #endif
            
        case .combine:
            return NSGraphicsContext.current != nil
            
        case .extractAudio:
            if #available(macOS 13.0, *) {
                let session = AVAssetExportSession(asset: AVAsset(), presetName: AVAssetExportPresetAppleM4A)
                return session?.supportedFileTypes.contains(.m4a) ?? false
            } else {
                return AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetAppleM4A)
            }
        default:
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
    
    func validateContext(_ context: CIContext?) throws {
        guard context != nil else {
            throw ConversionError.conversionFailed(reason: "Invalid graphics context")
        }
    }
    
    func validateType(_ type: Any.Type?) throws {
        guard let _ = type else {
            throw ConversionError.conversionFailed(reason: "Invalid type")
        }
    }
}
