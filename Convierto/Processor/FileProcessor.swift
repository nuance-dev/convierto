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
    case preparing
    
    var description: String {
        switch self {
        case .idle: return "Ready"
        case .analyzing: return "Analyzing file..."
        case .converting: return "Converting..."
        case .optimizing: return "Optimizing..."
        case .finalizing: return "Finalizing..."
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .preparing: return "Preparing..."
        }
    }
}

@MainActor
class FileProcessor: ObservableObject {
    @Published private(set) var currentStage: ConversionStage = .idle
    @Published private(set) var error: ConversionError?
    @Published var conversionProgress: Double = 0
    private var temporaryFiles: Set<URL> = []
    private var processingResults: [ProcessingResult] = []
    
    private let coordinator: ConversionCoordinator
    private let progressTracker = ProgressTracker()
    private var cancellables = Set<AnyCancellable>()
    let progress = Progress(totalUnitCount: 100)
    
    // Add processing state
    private var isActivelyProcessing: Bool = false
    
    init(settings: ConversionSettings = ConversionSettings()) {
        self.coordinator = ConversionCoordinator()
        setupProgressTracking()
    }
    
    private func determineInputType(_ url: URL) throws -> UTType {
        let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey])
        guard let contentType = resourceValues.contentType else {
            throw ConversionError.invalidInputType
        }
        return contentType
    }
    
    func processFile(_ url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        isActivelyProcessing = true
        defer { isActivelyProcessing = false }
        
        logger.debug("🔄 Starting file processing")
        logger.debug("📂 Input URL: \(url.path)")
        
        // Create metadata for the file
        let metadata = try await createMetadata(for: url)
        
        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: ConversionError.conversionFailed(reason: "FileProcessor was deallocated"))
                return
            }
            
            Task { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: ConversionError.conversionFailed(reason: "FileProcessor was deallocated"))
                    return
                }
                
                do {
                    let result = try await self.processFile(url, outputFormat: outputFormat, metadata: metadata)
                    self.processingResults.append(result)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func cleanup() {
        Task { @MainActor in
            // Only cleanup if we're not actively processing
            guard !isActivelyProcessing else {
                logger.debug("🚫 Skipping cleanup - active processing in progress")
                return
            }
            
            // Add delay before cleanup
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 second delay
            
            // Check again after delay
            guard !isActivelyProcessing else {
                logger.debug("🚫 Skipping cleanup - processing started during delay")
                return
            }
            
            logger.debug("🧹 Starting cleanup process")
            // Cancel any ongoing processing
            cancelProcessing()
            
            // Clear all files and results
            clearFiles()
            
            // Reset state
            currentStage = .idle
            conversionProgress = 0
            error = nil
            
            logger.debug("✅ Cleanup completed")
        }
    }
    
    deinit {
        cancellables.removeAll()
        Task { @MainActor [weak self] in
            await self?.cleanup()
        }
    }
    
    private func performProcessing(_ url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        logger.debug("🔄 Starting file processing")
        logger.debug("📂 Input URL: \(url.path)")
        logger.debug("🎯 Output format: \(outputFormat.identifier)")
        
        let progress = Progress(totalUnitCount: 100)
        logger.debug("⏳ Progress tracker initialized")
        
        // Validate file first
        let validator = FileValidator()
        logger.debug("🔍 Starting file validation")
        try await validator.validateFile(url)
        logger.debug("✅ File validation passed")
        
        // Create metadata
        logger.debug("📋 Creating metadata")
        let metadata = try await createMetadata(for: url)
        logger.debug("✅ Metadata created: \(String(describing: metadata))")
        
        // Ensure we have necessary permissions
        logger.debug("🔐 Checking file permissions")
        guard url.startAccessingSecurityScopedResource() else {
            logger.error("❌ Security-scoped resource access denied")
            throw ConversionError.fileAccessDenied(path: url.path)
        }
        
        defer {
            logger.debug("🔓 Releasing security-scoped resource")
            url.stopAccessingSecurityScopedResource()
        }
        
        logger.debug("⚙️ Initiating conversion process")
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
        conversionProgress = 0
        
        // Setup progress observation
        let progressObserver = progress.observe(\.fractionCompleted) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.conversionProgress = self?.progress.fractionCompleted ?? 0
            }
        }
        
        defer {
            progressObserver.invalidate()
        }
        
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
                // Image Conversions
                case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .image):
                    logger.debug("🎨 Processing image to image conversion")
                let imageProcessor = try ImageProcessor()
                    return try await imageProcessor.convert(
                        url,
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                    
                case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .movie):
                    logger.debug("🎬 Processing image to video conversion")
                let videoProcessor = try VideoProcessor()
                    return try await videoProcessor.convert(
                        url,
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                    
                case (let input, let output) where input.conforms(to: .image) && output.conforms(to: .pdf):
                    logger.debug("📄 Processing image to PDF conversion")
                let documentProcessor = try DocumentProcessor()
                    return try await documentProcessor.convert(
                        url,
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                
                // Video Conversions
                case (let input, let output) where input.conforms(to: .movie) && output.conforms(to: .movie):
                    logger.debug("🎬 Processing video format conversion")
                let videoProcessor = try VideoProcessor()
                    return try await videoProcessor.convert(
                        url,
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                    
                case (let input, let output) where input.conforms(to: .movie) && output.conforms(to: .image):
                    logger.debug("📸 Processing video frame extraction")
                let videoProcessor = try VideoProcessor()
                    let asset = AVURLAsset(url: url)
                    return try await videoProcessor.extractKeyFrame(
                        from: asset,
                        format: outputFormat,
                        metadata: metadata
                    )
                    
                case (let input, let output) where input.conforms(to: .movie) && output.conforms(to: .audio):
                    logger.debug("🎵 Processing video audio extraction")
                    let videoProcessor = try VideoProcessor()
                    return try await videoProcessor.extractAudio(
                        from: AVURLAsset(url: url),
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                    
                // Audio Conversions
                case (let input, let output) where input.conforms(to: .audio) && output.conforms(to: .audio):
                    logger.debug("🎵 Processing audio format conversion")
                let audioProcessor = try AudioProcessor()
                _ = AVURLAsset(url: url)
                    return try await audioProcessor.convert(
                        url,
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                    
                case (let input, let output) where input.conforms(to: .audio) && output.conforms(to: .movie):
                    logger.debug("🎵 Processing audio visualization to video")
                let audioProcessor = try AudioProcessor()
                _ = try await CacheManager.shared.createTemporaryURL(for: output.preferredFilenameExtension ?? "mp4")
                    let result = try await audioProcessor.convert(
                        url,
                        to: output,
                        metadata: metadata,
                        progress: progress
                    )
                    
                    return ProcessingResult(
                        outputURL: result.outputURL,
                        originalFileName: result.originalFileName,
                        suggestedFileName: "audio_visualization." + (output.preferredFilenameExtension ?? "mp4"),
                        fileType: output,
                        metadata: result.metadata
                    )
                    
                case (let input, let output) where input.conforms(to: .audio) && output.conforms(to: .image):
                    logger.debug("📊 Processing audio waveform generation")
                let audioProcessor = try AudioProcessor()
                    let asset = AVURLAsset(url: url)
                    return try await audioProcessor.createWaveformImage(
                        from: asset,
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                
                // PDF Conversions
                case (let input, let output) where input.conforms(to: .pdf) && output.conforms(to: .image):
                    logger.debug("🖼️ Processing PDF to image conversion")
                let documentProcessor = try DocumentProcessor()
                    return try await documentProcessor.convert(
                        url,
                        to: outputFormat,
                        metadata: metadata,
                        progress: progress
                    )
                    
                case (let input, let output) where input.conforms(to: .pdf) && output.conforms(to: .movie):
                    logger.debug("🎬 Processing PDF to video conversion")
                let documentProcessor = try DocumentProcessor()
                    return try await documentProcessor.convert(
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
        progress.publisher(for: \.fractionCompleted)
            .sink { [weak self] value in
                Task { @MainActor in
                    self?.conversionProgress = value
                }
            }
            .store(in: &cancellables)
    }
    
    private func validateInput(_ url: URL) async throws -> UTType {
        let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
        guard let contentType = resourceValues.contentType else {
            throw ConversionError.invalidInputType
        }
        
        // Check if file is readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionError.fileAccessDenied(path: url.path)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = attributes[.size] as? UInt64,
              fileSize > 0 else {
            throw ConversionError.invalidInput
        }
        
        return contentType
    }
    
    private func validateCompatibility(input: UTType, output: UTType) async throws {
        logger.debug("🔍 Validating format compatibility")
        logger.debug("📄 Input: \(input.identifier)")
        logger.debug("🎯 Output: \(output.identifier)")
        
        // For audio-to-audio conversion
        if input.conforms(to: .audio) && output.conforms(to: .audio) {
            logger.debug("✅ Audio to audio conversion validated")
            return
        }
        
        // Validate audio to video conversion
        if input.conforms(to: .audio) && output.conforms(to: .audiovisualContent) {
            guard output == .mpeg4Movie else {
                throw ConversionError.incompatibleFormats(
                    from: input,
                    to: output
                )
            }
            
            // Check memory requirements
            let requiredMemory: UInt64 = 750_000_000 // 750MB for audio visualization
            let available = await ResourcePool.shared.getAvailableMemory()
            
            guard available >= requiredMemory else {
                throw ConversionError.insufficientMemory(
                    required: requiredMemory,
                    available: available
                )
            }
        }
        
        logger.debug("✅ Format compatibility validated")
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
        
        logger.debug("️ Checking format compatibility")
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
            originalFileName: resourceValues.name,
            originalFileType: resourceValues.contentType,
            creationDate: resourceValues.creationDate,
            modificationDate: resourceValues.contentModificationDate,
            fileSize: Int64(resourceValues.fileSize ?? 0)
        )
    }
    
    @MainActor
    func cancelProcessing() {
        currentStage = .idle
        error = ConversionError.cancelled
        conversionProgress = 0
    }
    
    private func clearFiles() {
        logger.debug("🗑 Clearing temporary files and results")
        
        // Clear processing results
        processingResults.removeAll()
        
        // Remove temporary files
        for url in temporaryFiles {
            do {
                try FileManager.default.removeItem(at: url)
                logger.debug("✅ Removed temporary file: \(url.lastPathComponent)")
            } catch {
                logger.error("❌ Failed to remove temporary file: \(url.lastPathComponent), error: \(error.localizedDescription)")
            }
        }
        
        // Clear the set of temporary files
        temporaryFiles.removeAll()
        
        logger.debug("✅ All temporary files cleared")
    }
}
