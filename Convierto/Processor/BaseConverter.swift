import Foundation
import AVFoundation
import UniformTypeIdentifiers

protocol MediaConverting {
    func convert(_ url: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult
    func canConvert(from: UTType, to: UTType) -> Bool
    var settings: ConversionSettings { get }
}

class BaseConverter {
    let settings: ConversionSettings
    
    init(settings: ConversionSettings = ConversionSettings()) {
        self.settings = settings
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
}
