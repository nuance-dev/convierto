import AVFoundation

@available(macOS 14.0, *)
actor SendableExportSession: @unchecked Sendable {
    private let session: AVAssetExportSession
    private var progressObserver: NSKeyValueObservation?
    
    init?(_ asset: AVAsset, presetName: String) {
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            return nil
        }
        self.session = session
    }
    
    var progress: Float {
        session.progress
    }
    
    var status: AVAssetExportSession.Status {
        session.status
    }
    
    var error: Error? {
        session.error
    }
    
    func configureExport(outputURL: URL, outputFileType: AVFileType) {
        session.outputURL = outputURL
        session.outputFileType = outputFileType
        session.shouldOptimizeForNetworkUse = true
    }
    
    func export() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            session.exportAsynchronously {
                switch self.session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: self.session.error ?? ConversionError.exportFailed)
                case .cancelled:
                    continuation.resume(throwing: ConversionError.conversionFailed)
                default:
                    continuation.resume(throwing: ConversionError.exportFailed)
                }
            }
        }
    }
    
    func observeProgress(_ handler: @escaping (Float) -> Void) {
        progressObserver = session.observe(\.progress, options: [.new]) { _, change in
            if let newValue = change.newValue {
                handler(newValue)
            }
        }
    }
    
    deinit {
        progressObserver?.invalidate()
    }
} 