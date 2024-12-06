import Foundation

extension NSNotification.Name {
    static let conversionProgressUpdated = NSNotification.Name("com.convierto.conversionProgressUpdated")
    static let memoryPressureWarning = NSNotification.Name("com.convierto.memoryPressureWarning")
}

class ProgressMonitor {
    private let progress: Progress
    private var observation: NSKeyValueObservation?
    
    init(progress: Progress) {
        self.progress = progress
    }
    
    func start() {
        NotificationCenter.default.post(
            name: .conversionProgressUpdated,
            object: nil,
            userInfo: ["progress": 0.0]
        )
        
        observation = progress.observe(\.fractionCompleted) { progress, _ in
            NotificationCenter.default.post(
                name: .conversionProgressUpdated,
                object: nil,
                userInfo: ["progress": progress.fractionCompleted]
            )
        }
    }
    
    func stop() {
        observation?.invalidate()
        observation = nil
    }
}