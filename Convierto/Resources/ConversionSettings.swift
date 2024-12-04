import Foundation
import CoreGraphics
import AVFoundation

public struct ConversionSettings {
    // Image conversion settings
    var imageQuality: CGFloat = 0.95
    var preserveMetadata: Bool = true
    var maintainAspectRatio: Bool = true
    var resizeImage: Bool = false
    var targetSize: CGSize = CGSize(width: 1920, height: 1080)
    var enhanceImage: Bool = false
    var adjustColors: Bool = false
    var saturation: Double = 1.0
    var brightness: Double = 0.0
    var contrast: Double = 1.0
    
    // Video conversion settings
    var videoQuality: String = AVAssetExportPresetHighestQuality
    var videoBitRate: Int?
    var audioBitRate: Int?
    var frameRate: Int = 30
    var videoDuration: Double = 3.0
    
    // Animation settings
    var gifFrameCount: Int = 10
    var gifFrameDuration: Double = 0.1
    var animationStyle: AnimationStyle = .none
    
    public enum AnimationStyle {
        case none
        case zoom
        case rotate
    }
    
    public init(
        imageQuality: CGFloat = 0.95,
        preserveMetadata: Bool = true,
        maintainAspectRatio: Bool = true,
        resizeImage: Bool = false,
        targetSize: CGSize = CGSize(width: 1920, height: 1080),
        enhanceImage: Bool = false,
        adjustColors: Bool = false,
        saturation: Double = 1.0,
        brightness: Double = 0.0,
        contrast: Double = 1.0,
        videoQuality: String = AVAssetExportPresetHighestQuality,
        videoBitRate: Int? = nil,
        audioBitRate: Int? = nil,
        frameRate: Int = 30,
        videoDuration: Double = 3.0,
        gifFrameCount: Int = 10,
        gifFrameDuration: Double = 0.1,
        animationStyle: AnimationStyle = .none
    ) {
        self.imageQuality = imageQuality
        self.preserveMetadata = preserveMetadata
        self.maintainAspectRatio = maintainAspectRatio
        self.resizeImage = resizeImage
        self.targetSize = targetSize
        self.enhanceImage = enhanceImage
        self.adjustColors = adjustColors
        self.saturation = saturation
        self.brightness = brightness
        self.contrast = contrast
        self.videoQuality = videoQuality
        self.videoBitRate = videoBitRate
        self.audioBitRate = audioBitRate
        self.frameRate = frameRate
        self.videoDuration = videoDuration
        self.gifFrameCount = gifFrameCount
        self.gifFrameDuration = gifFrameDuration
        self.animationStyle = animationStyle
    }
}
