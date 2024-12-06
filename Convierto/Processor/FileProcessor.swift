import Combine
import Foundation
import UniformTypeIdentifiers
import AppKit
import os.log
import AVFoundation

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
    category: "FileProcessor"
)

struct ProcessingResult {
    let outputURL: URL
    let originalFileName: String
    let suggestedFileName: String
    let fileType: UTType
    let metadata: [String: Any]?
    
    init(outputURL: URL, originalFileName: String?, suggestedFileName: String?, fileType: UTType, metadata: [String: Any]?) {
        self.outputURL = outputURL
        self.originalFileName = originalFileName ?? "unknown"
        self.suggestedFileName = suggestedFileName ?? "converted_file"
        self.fileType = fileType
        self.metadata = metadata
    }
}

enum ConversionStage {
    case idle
    case analyzing
    case converting
    case optimizing
    case finalizing
    case completed
    case failed
    
    var description: String {
        switch self {
        case .idle: return "Ready"
        case .analyzing: return "Analyzing file..."
        case .converting: return "Converting..."
        case .optimizing: return "Optimizing..."
        case .finalizing: return "Finalizing..."
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
}

@MainActor
class FileProcessor: ObservableObject {
    @Published private(set) var currentStage: ConversionStage = .idle
    @Published private(set) var error: ConversionError?
    @Published private(set) var conversionProgress: Double = 0
    
    private let coordinator: ConversionCoordinator
    private let progressTracker = ProgressTracker()
    private var cancellables = Set<AnyCancellable>()
    private let progress = Progress(totalUnitCount: 100)
    
    init(settings: ConversionSettings = ConversionSettings()) {
        self.coordinator = ConversionCoordinator()
        setupProgressTracking()
    }
    
    private func determineInputType(_ url: URL) async throws -> UTType {
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
        guard let contentType = resourceValues.contentType else {
            throw ConversionError.invalidInputType
        }
        return contentType
    }
    
    func processFile(_ url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        let progress = Progress(totalUnitCount: 100)
        
        // Create metadata asynchronously
        let metadata = ConversionMetadata(
            originalFileName: url.lastPathComponent,
            originalFileType: try await determineInputType(url),
            creationDate: try await url.resourceValues(forKeys: [.creationDateKey]).creationDate,
            modificationDate: try await url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            fileSize: Int64(try await url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        )
        
        // Check system resources
        let requiredMemory: UInt64 = 100_000_000 // 100MB minimum
        try await ResourcePool.shared.checkMemoryAvailability(required: requiredMemory)
        
        return try await coordinator.convert(
            url: url,
            to: outputFormat,
            metadata: metadata,
            progress: progress
        )
    }
    
    func processFile(_ url: URL, outputFormat: UTType, metadata: ConversionMetadata) async throws -> ProcessingResult {
        currentStage = .analyzing
        
        do {
            let inputType = try await validateInput(url)
            try await validateCompatibility(input: inputType, output: outputFormat)
            
            currentStage = .converting
            
            let result = try await coordinator.convert(
                url: url,
                to: outputFormat,
                metadata: metadata,
                progress: progress
            )
            
            currentStage = .completed
            return result
            
        } catch let error as ConversionError {
            currentStage = .failed
            self.error = error
            throw error
        }
    }
    
    private func setupProgressTracking() {
        progressTracker.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progressValue in
                self?.conversionProgress = progressValue
                self?.progress.completedUnitCount = Int64(progressValue * 100)
            }
            .store(in: &cancellables)
    }
    
    private func validateInput(_ url: URL) async throws -> UTType {
        guard let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = resourceValues.contentType else {
            throw ConversionError.invalidInputType
        }
        
        // Check if file is readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionError.fileAccessDenied(path: url.path)
        }
        
        // Validate file size
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? UInt64,
              fileSize > 0 else {
            throw ConversionError.invalidInput
        }
        
        return contentType
    }
    
    private func validateCompatibility(input: UTType, output: UTType) async throws {
        // Check basic compatibility
        if input == output {
            return // Same format, always compatible
        }
        
        // Check for supported conversion paths
        switch (input, output) {
        case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .image):
            return // Image to image conversion is supported
            
        case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .movie):
            // Image to video requires special handling
            let requiredMemory: UInt64 = 500_000_000 // 500MB
            let available = await ResourcePool.shared.getAvailableMemory()
            guard available >= requiredMemory else {
                throw ConversionError.insufficientMemory(
                    required: requiredMemory,
                    available: available
                )
            }
            
        default:
            throw ConversionError.incompatibleFormats(from: input, to: output)
        }
    }
    
    private func determineConversionStrategy(input: UTType, output: UTType) -> ConversionStrategy {
        switch (input, output) {
        case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .movie):
            return .createVideo
        case (let input, let output) where input.conforms(to: .audio) && output.conforms(to: .movie):
            return .visualize
        case (let input, let output) where input.conforms(to: .movie) && output.conforms(to: .image):
            return .extractFrame
        case (let input, let output) where input.conforms(to: .movie) && output.conforms(to: .audio):
            return .extractAudio
        default:
            return .direct
        }
    }
    
    func determineStrategy(from inputType: UTType, to outputType: UTType) throws -> ConversionStrategy {
        // Check basic compatibility
        if inputType == outputType {
            return .direct
        }
        
        switch (inputType, outputType) {
        case (let i, let o) where i.conforms(to: .image) && o.conforms(to: .audiovisualContent):
            return .createVideo
        case (let i, let o) where i.conforms(to: .audio) && o.conforms(to: .audiovisualContent):
            return .visualize
        case (let i, let o) where i.conforms(to: .audiovisualContent) && o.conforms(to: .image):
            return .extractFrame
        case (let i, let o) where i.conforms(to: .audiovisualContent) && o.conforms(to: .audio):
            return .extractAudio
        case (let i, let o) where i.conforms(to: .image) && o == .pdf:
            return .combine
        case (.pdf, let o) where o.conforms(to: .image):
            return .extractFrame
        default:
            throw ConversionError.incompatibleFormats(from: inputType, to: outputType)
        }
    }
    
    private func createMetadata(for url: URL) async throws -> ConversionMetadata {
        let resourceValues = try await url.resourceValues(forKeys: [
            .contentTypeKey,
            .nameKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ])
        
        return ConversionMetadata(
            originalFileName: resourceValues.name ?? "unknown",
            originalFileType: resourceValues.contentType,
            creationDate: resourceValues.creationDate,
            modificationDate: resourceValues.contentModificationDate,
            fileSize: Int64(resourceValues.fileSize ?? 0)
        )
    }
}
