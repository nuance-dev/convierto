import Foundation

struct AudioProcessorConfig {
    let maxFrameCount: Int
    let defaultFPS: Int
    let conversionTimeout: TimeInterval
    var waveformSize: CGSize
    let defaultBufferSize: Int
    
    static let `default` = AudioProcessorConfig(
        maxFrameCount: 1800,
        defaultFPS: 30,
        conversionTimeout: 300,
        waveformSize: CGSize(width: 1920, height: 480),
        defaultBufferSize: 1024 * 1024
    )
    
    func validate() throws {
        guard maxFrameCount > 0 else {
            throw ConversionError.invalidConfiguration("Frame count must be positive")
        }
        guard defaultFPS > 0 else {
            throw ConversionError.invalidConfiguration("FPS must be positive")
        }
        guard conversionTimeout > 0 else {
            throw ConversionError.invalidConfiguration("Timeout must be positive")
        }
    }
} 