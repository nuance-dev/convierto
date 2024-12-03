import Foundation
import CoreGraphics

public struct CompressionSettings {
    var quality: CGFloat = 0.7        // JPEG/HEIC quality (0.0-1.0)
    var pngCompressionLevel: Int = 6  // PNG compression (0-9)
    var preserveMetadata: Bool = false
    var maxDimension: CGFloat? = nil  // Downsample if larger
    var optimizeForWeb: Bool = true   // Additional optimizations for web use
    var audioBitRate: Int?        // In bits per second
    var audioSampleRate: Double? // In Hertz
    
    public init(
        quality: CGFloat = 0.7,
        pngCompressionLevel: Int = 6,
        preserveMetadata: Bool = false,
        maxDimension: CGFloat? = nil,
        optimizeForWeb: Bool = true
    ) {
        self.quality = quality
        self.pngCompressionLevel = pngCompressionLevel
        self.preserveMetadata = preserveMetadata
        self.maxDimension = maxDimension
        self.optimizeForWeb = optimizeForWeb
    }
}
