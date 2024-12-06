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
        
        // Validate file first
        let validator = FileValidator()
        try await validator.validateFile(url)
        
        // Create metadata
        let metadata = try await createMetadata(for: url)
        
        // Ensure we have necessary permissions
        guard url.startAccessingSecurityScopedResource() else {
            throw ConversionError.fileAccessDenied(path: url.path)
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        return try await coordinator.convert(
            url: url,
            to: outputFormat,
            metadata: metadata,
            progress: progress
        )
    }
    
    func processFile(_ url: URL, outputFormat: UTType, metadata: ConversionMetadata) async throws -> ProcessingResult {
        logger.debug("🔄 Starting file processing pipeline")
        logger.debug("📂 Input file: \(url.path)")
        logger.debug("🎯 Target format: \(outputFormat.identifier)")
        
        currentStage = .analyzing
        
        do {
            logger.debug("🔍 Step 1: Validating input type")
            let inputType = try await validateInput(url)
            logger.debug("✅ Input type validated: \(inputType.identifier)")
            
            logger.debug("🔍 Step 2: Checking format compatibility")
            try await validateCompatibility(input: inputType, output: outputFormat)
            logger.debug("✅ Format compatibility validated")
            
            currentStage = .converting
            logger.debug("⚙️ Current stage: Converting")
            
            switch (inputType, outputFormat) {
                case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .image):
                    logger.debug("🎨 Processing image to image conversion")
                    let imageProcessor = ImageProcessor()
                    return try await imageProcessor.convert(
                        url,
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                    
                case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .movie):
                    logger.debug("🎬 Processing image to video conversion")
                    let videoProcessor = VideoProcessor()
                    return try await videoProcessor.convert(
                        url,
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                    
                default:
                    logger.error("❌ Unsupported conversion combination: \(inputType.identifier) -> \(outputFormat.identifier)")
                    throw ConversionError.conversionNotPossible(reason: "Unsupported conversion type")
            }
            
        } catch {
            currentStage = .failed
            logger.error("❌ Conversion failed: \(error.localizedDescription)")
            self.error = error as? ConversionError ?? ConversionError.conversionFailed(reason: error.localizedDescription)
            throw self.error!
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
        logger.debug("Validating compatibility from \(input.identifier) to \(output.identifier)")
        
        // Check basic compatibility
        if input == output {
            logger.debug("Same format conversion, skipping compatibility check")
            return
        }
        
        // Check for supported conversion paths
        switch (input, output) {
        case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .image):
            logger.debug("Image to image conversion validated")
            return
            
        case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .movie):
            logger.debug("Checking resources for image to video conversion")
            let requiredMemory: UInt64 = 500_000_000 // 500MB
            let available = await ResourcePool.shared.getAvailableMemory()
            guard available >= requiredMemory else {
                logger.error("Insufficient memory: required \(requiredMemory), available \(available)")
                throw ConversionError.insufficientMemory(
                    required: requiredMemory,
                    available: available
                )
            }
            logger.debug("Resource check passed for image to video conversion")
            
        default:
            logger.error("Incompatible formats: \(input.identifier) to \(output.identifier)")
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
        logger.debug("🔍 Determining strategy for conversion")
        logger.debug("📄 Input type: \(inputType.identifier)")
        logger.debug("🎯 Output type: \(outputType.identifier)")
        
        // Check basic compatibility
        if inputType == outputType {
            logger.debug("✅ Direct conversion possible - same types")
            return .direct
        }
        
        logger.debug("⚙️ Checking format compatibility")
        switch (inputType, to: outputType) {
        case (let i, let o) where i.conforms(to: .image) && o.conforms(to: .image):
            logger.debug("✅ Image to image conversion strategy selected")
            return .direct
        case (let i, let o) where i.conforms(to: .image) && o.conforms(to: .audiovisualContent):
            logger.debug("✅ Image to video conversion strategy selected")
            return .createVideo
        case (let i, let o) where i.conforms(to: .audio) && o.conforms(to: .audiovisualContent):
            logger.debug("✅ Audio visualization strategy selected")
            return .visualize
        case (let i, let o) where i.conforms(to: .audiovisualContent) && o.conforms(to: .image):
            logger.debug("✅ Frame extraction strategy selected")
            return .extractFrame
        case (let i, let o) where i.conforms(to: .audiovisualContent) && o.conforms(to: .audio):
            logger.debug("✅ Audio extraction strategy selected")
            return .extractAudio
        case (let i, let o) where i.conforms(to: .image) && o == .pdf:
            logger.debug("✅ Image to PDF combination strategy selected")
            return .combine
        case (.pdf, let o) where o.conforms(to: .image):
            logger.debug("✅ PDF frame extraction strategy selected")
            return .extractFrame
        default:
            logger.error("❌ No valid conversion strategy found")
            logger.error("📄 Input type: \(inputType.identifier)")
            logger.error("🎯 Output type: \(outputType.identifier)")
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
