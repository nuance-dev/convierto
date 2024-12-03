import Foundation
import CoreGraphics
import AVFoundation

public struct ConversionSettings {
    // Image conversion settings
    var imageQuality: CGFloat = 0.95        // Quality for lossy formats (0.0-1.0)
    var preserveMetadata: Bool = true       // Preserve image metadata during conversion
    var maintainAspectRatio: Bool = true    // Keep aspect ratio during conversion
    
    // Video conversion settings
    var videoQuality: String = AVAssetExportPresetHighestQuality
    var videoBitRate: Int?                  // Video bit rate in bits per second
    var audioBitRate: Int?                  // Audio bit rate in bits per second
    var frameRate: Int?                     // Target frame rate
    
    // Audio conversion settings
    var audioQuality: Int = 320            // Audio quality in kbps
    var audioChannels: Int = 2             // Number of audio channels
    var audioSampleRate: Double = 44100    // Sample rate in Hz
    
    public init(
        imageQuality: CGFloat = 0.95,
        preserveMetadata: Bool = true,
        maintainAspectRatio: Bool = true,
        videoQuality: String = AVAssetExportPresetHighestQuality,
        audioBitRate: Int? = nil,
        frameRate: Int? = nil,
        audioQuality: Int = 320,
        audioChannels: Int = 2,
        audioSampleRate: Double = 44100
    ) {
        self.imageQuality = imageQuality
        self.preserveMetadata = preserveMetadata
        self.maintainAspectRatio = maintainAspectRatio
        self.videoQuality = videoQuality
        self.audioBitRate = audioBitRate
        self.frameRate = frameRate
        self.audioQuality = audioQuality
        self.audioChannels = audioChannels
        self.audioSampleRate = audioSampleRate
    }
}
