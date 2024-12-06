import Foundation

class MemoryPressureHandler {
    var onPressureChange: ((MemoryPressureLevel) -> Void)?
    private var observer: Any?
    
    init() {
        setupMemoryPressureNotification()
    }
    
    private func setupMemoryPressureNotification() {
        observer = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        
        if let pressureSource = observer as? DispatchSourceMemoryPressure {
            pressureSource.setEventHandler { [weak self] in
                let pressure: MemoryPressureLevel
                switch pressureSource.data {
                case .warning:
                    pressure = .warning
                case .critical:
                    pressure = .critical
                default:
                    pressure = .normal
                }
                self?.onPressureChange?(pressure)
            }
            
            pressureSource.resume()
        }
    }
    
    deinit {
        if let pressureSource = observer as? DispatchSourceMemoryPressure {
            pressureSource.cancel()
        }
    }
}

enum MemoryPressureLevel {
    case normal
    case warning
    case critical
} 