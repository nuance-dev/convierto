import Foundation
import CoreGraphics

enum WaveformStyle {
    case line
    case bars
    case filled
    case dots
    
    var lineWidth: CGFloat {
        switch self {
        case .line:
            return 1.0
        case .bars:
            return 2.0
        case .filled:
            return 3.0
        case .dots:
            return 4.0
        }
    }
} 