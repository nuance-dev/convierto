import Foundation
import UniformTypeIdentifiers

class ProcessorFactory {
    static let shared = ProcessorFactory()
    private var processors: [String: BaseConverter] = [:]
    private let settings: ConversionSettings
    
    init(settings: ConversionSettings = ConversionSettings()) {
        self.settings = settings
    }
    
    func processor(for type: UTType) -> BaseConverter {
        let key = type.identifier
        
        if let existing = processors[key] {
            return existing
        }
        
        let processor: BaseConverter
        
        if type.conforms(to: .image) {
            processor = ImageProcessor(settings: settings)
        } else if type.conforms(to: .audiovisualContent) {
            processor = VideoProcessor(settings: settings)
        } else if type.conforms(to: .audio) {
            processor = AudioProcessor(settings: settings)
        } else if type == .pdf {
            processor = DocumentProcessor(settings: settings)
        } else {
            processor = BaseConverter(settings: settings)
        }
        
        processors[key] = processor
        return processor
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