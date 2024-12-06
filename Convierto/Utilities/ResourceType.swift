import Foundation

enum ResourceType {
    case conversion(ConversionStrategy)
    case document
    case image
    case video
    case audio
    
    var memoryRequirement: UInt64 {
        switch self {
        case .conversion(let strategy):
            switch strategy {
            case .direct: return 250_000_000 // 250MB
            case .extractFrame: return 500_000_000 // 500MB
            case .createVideo: return 750_000_000 // 750MB
            case .combine: return 1_000_000_000 // 1GB
            case .visualize: return 750_000_000 // 750MB
            case .extractAudio: return 250_000_000 // 250MB
            }
        case .document: return 500_000_000 // 500MB
        case .image: return 250_000_000 // 250MB
        case .video: return 750_000_000 // 750MB
        case .audio: return 100_000_000 // 100MB
        }
    }
}
