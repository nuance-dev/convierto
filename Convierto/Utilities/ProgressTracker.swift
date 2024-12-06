import Foundation
import Combine
import SwiftUI

class ProgressTracker: ObservableObject {
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentStage: ConversionStage = .preparing
    @Published private(set) var isIndeterminate: Bool = false
    @Published private(set) var statusMessage: String = ""
    
    private var subOperations: [String: Double] = [:]
    private var observations: Set<AnyCancellable> = []
    private let lock = NSLock()
    
    enum ConversionStage: String {
        case preparing = "Preparing"
        case loading = "Loading Resources"
        case analyzing = "Analyzing"
        case processing = "Converting"
        case optimizing = "Optimizing"
        case exporting = "Exporting"
        case finishing = "Finishing Up"
        case failed = "Failed"
        case completed = "Completed"
        
        var stageMessage: String {
            return self.rawValue
        }
        
        var systemImage: String {
            switch self {
            case .preparing: return "gear"
            case .loading: return "arrow.down.circle"
            case .analyzing: return "magnifyingglass"
            case .processing: return "wand.and.stars"
            case .optimizing: return "slider.horizontal.3"
            case .exporting: return "square.and.arrow.up"
            case .finishing: return "checkmark.circle"
            case .failed: return "exclamationmark.triangle"
            case .completed: return "checkmark.circle.fill"
            }
        }
    }
    
    func trackProgress(of progress: Progress, for operation: String) {
        progress.publisher(for: \.fractionCompleted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.updateProgress(for: operation, progress: value)
            }
            .store(in: &observations)
    }
    
    func updateProgress(for operation: String, progress: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        subOperations[operation] = progress
        calculateOverallProgress()
    }
    
    func setStage(_ stage: ConversionStage, message: String? = nil) {
        DispatchQueue.main.async {
            self.currentStage = stage
            if let message = message {
                self.statusMessage = message
            }
        }
    }
    
    func setIndeterminate(_ indeterminate: Bool) {
        DispatchQueue.main.async {
            self.isIndeterminate = indeterminate
        }
    }
    
    private func calculateOverallProgress() {
        let total = subOperations.values.reduce(0, +)
        let count = Double(max(1, subOperations.count))
        let overall = total / count
        
        DispatchQueue.main.async {
            self.progress = min(1.0, max(0.0, overall))
        }
    }
    
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        subOperations.removeAll()
        observations.removeAll()
        
        DispatchQueue.main.async {
            self.progress = 0
            self.currentStage = .preparing
            self.isIndeterminate = false
            self.statusMessage = ""
        }
    }
} 