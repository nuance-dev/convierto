import AVFoundation

@available(macOS 14.0, *)
actor SendableExportSession {
    private let session: AVAssetExportSession
    
    init(_ session: AVAssetExportSession) {
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
    
    func export() async throws {
        await session.export()
        
        guard session.status == .completed else {
            throw session.error ?? ConversionError.exportFailed
        }
    }
} 