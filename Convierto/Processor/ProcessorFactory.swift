import Foundation
import UniformTypeIdentifiers
import OSLog

class ProcessorFactory {
    private static var _shared: ProcessorFactory?
    static var shared: ProcessorFactory {
        guard let existing = _shared else {
            fatalError("ProcessorFactory.shared accessed before initialization. Call setupShared(coordinator:) first")
        }
        return existing
    }
    
    private var processors: [String: BaseConverter] = [:]
    private let settings: ConversionSettings
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "ProcessorFactory")
    weak var coordinator: ConversionCoordinator?
    
    static func setupShared(coordinator: ConversionCoordinator, settings: ConversionSettings = ConversionSettings()) {
        _shared = ProcessorFactory(settings: settings, coordinator: coordinator)
    }
    
    init(settings: ConversionSettings = ConversionSettings(), coordinator: ConversionCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }
    
    func processor(for type: UTType) throws -> BaseConverter {
        let key = type.identifier
        
        if let existing = processors[key] {
            return existing
        }
        
        let processor: BaseConverter
        
        do {
            if type.conforms(to: .image) {
                processor = try ImageProcessor(settings: settings)
            } else if type.conforms(to: .audiovisualContent) {
                processor = try VideoProcessor(settings: settings)
            } else if type.conforms(to: .audio) {
                processor = try AudioProcessor(settings: settings)
            } else if type == .pdf {
                processor = try DocumentProcessor(settings: settings)
            } else {
                processor = try BaseConverter(settings: settings)
            }
            
            processors[key] = processor
            logger.debug("Created processor for type: \(type.identifier)")
            return processor
        } catch {
            logger.error("Failed to create processor: \(error.localizedDescription)")
            throw ConversionError.invalidConfiguration("Failed to create processor: \(error.localizedDescription)")
        }
    }
    
    func releaseProcessor(for type: UTType) {
        processors.removeValue(forKey: type.identifier)
    }
    
    nonisolated func cleanup() {
        Task { @MainActor in
            processors.removeAll()
        }
    }
} 
