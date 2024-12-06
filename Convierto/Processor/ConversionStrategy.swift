import Foundation

enum ConversionStrategy {
    case direct           // Standard conversion
    case extractFrame     // Video to Image
    case createVideo      // Image to Video
    case visualize       // Audio to Video/Image
    case extractAudio    // Video to Audio
    case combine         // Multiple files to one
    
    var requiresBuffering: Bool {
        switch self {
        case .direct: return false
        case .extractFrame: return true
        case .createVideo: return true
        case .visualize: return true
        case .extractAudio: return false
        case .combine: return true
        }
    }
    
    var estimatedMemoryUsage: Int64 {
        switch self {
        case .direct: return 100_000_000     // 100MB
        case .extractFrame: return 500_000_000  // 500MB
        case .createVideo: return 1_000_000_000 // 1GB
        case .visualize: return 750_000_000   // 750MB
        case .extractAudio: return 250_000_000  // 250MB
        case .combine: return 1_500_000_000  // 1.5GB
        }
    }
    
    var canFallback: Bool {
        switch self {
        case .direct: return false
        case .extractFrame: return true
        case .createVideo: return true
        case .visualize: return true
        case .extractAudio: return false
        case .combine: return true
        }
    }
}