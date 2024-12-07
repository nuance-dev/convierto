import Foundation
import UniformTypeIdentifiers
import SwiftUI
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
    category: "MultiFileProcessingView"
)

struct FileProcessingState: Identifiable {
    let id: UUID
    let url: URL
    let originalFileName: String
    var progress: Double
    var result: ProcessingResult?
    var isProcessing: Bool
    var error: Error?
    var stage: ConversionStage = .idle
    
    // Add this computed property
    var displayFileName: String {
        // If the filename contains UUID prefix, remove it
        let filename = url.lastPathComponent
        if let range = filename.range(of: "_") {
            return String(filename[range.upperBound...])
        }
        return originalFileName
    }
    
    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.originalFileName = url.lastPathComponent
        self.progress = 0
        self.result = nil
        self.isProcessing = false
        self.error = nil
        self.stage = .idle
    }
}

@MainActor
class MultiFileProcessor: ObservableObject {
    @Published private(set) var files: [FileProcessingState] = []
    @Published private(set) var isProcessingMultiple = false
    @Published var selectedOutputFormat: UTType = .jpeg
    @Published var progress: Double = 0
    @Published var isProcessing: Bool = false
    @Published var processingResult: ProcessingResult?
    @Published var error: ConversionError?
    @Published var conversionResult: ProcessingResult?
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    private var currentTask: Task<Void, Never>?
    
    func addFiles(_ urls: [URL]) {
        let newFiles = urls.map { FileProcessingState(url: $0) }
        files.append(contentsOf: newFiles)
        
        // Process each new file individually
        for file in newFiles {
            processFile(with: file.id)
        }
    }
    
    func removeFile(at index: Int) {
        guard index < files.count else { return }
        let fileId = files[index].id
        processingTasks[fileId]?.cancel()
        processingTasks.removeValue(forKey: fileId)
        files.remove(at: index)
    }
    
    func clearFiles(completion: (() -> Void)? = nil) {
        // Cancel all ongoing processing tasks
        for task in processingTasks.values {
            task.cancel()
        }
        processingTasks.removeAll()
        files.removeAll()
        completion?()
    }
    
    private func processFile(with id: UUID) {
        let task = Task {
            await processFileInternal(with: id)
        }
        processingTasks[id] = task
        currentTask = task
    }
    
    func saveAllFilesToFolder() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let panel = NSOpenPanel()
                    panel.canCreateDirectories = true
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.message = "Choose where to save all converted files"
                    panel.prompt = "Select Folder"
                    
                    guard let window = NSApp.windows.first else { 
                        throw ConversionError.conversionFailed(reason: "No window available")
                    }
                    
                    let response = await panel.beginSheetModal(for: window)
                    
                    if response == .OK, let folderURL = panel.url {
                        for file in files {
                            if let result = file.result {
                                do {
                                    let destinationURL = folderURL.appendingPathComponent(result.suggestedFileName)
                                    try FileManager.default.copyItem(at: result.outputURL, to: destinationURL)
                                } catch {
                                    throw ConversionError.exportFailed(reason: "Failed to save file: \(error.localizedDescription)")
                                }
                            }
                        }
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ConversionError.cancelled)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    @MainActor
    private func processFileInternal(with id: UUID) async {
        guard let fileState = files.first(where: { $0.id == id }) else { return }
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        
        files[index].isProcessing = true
        files[index].progress = 0
        files[index].stage = .analyzing
        isProcessing = true
        
        do {
            let processor = FileProcessor()
            
            let progressObserver = processor.$conversionProgress
                .sink { [weak self] progress in
                    guard let self = self else { return }
                    self.files[index].progress = progress
                    
                    // Update stage based on progress
                    if progress < 0.2 {
                        self.files[index].stage = .analyzing
                    } else if progress < 0.8 {
                        self.files[index].stage = .converting
                    } else if progress < 1.0 {
                        self.files[index].stage = .optimizing
                    }
                    
                    self.updateOverallProgress()
                }
            
            let result = try await processor.processFile(fileState.url, outputFormat: selectedOutputFormat)
            
            if !Task.isCancelled {
                files[index].result = result
                files[index].progress = 1.0
                files[index].stage = .completed
            }
            
            progressObserver.cancel()
        } catch {
            files[index].error = error
            files[index].stage = .failed
        }
        
        files[index].isProcessing = false
        isProcessing = files.contains(where: { $0.isProcessing })
        updateOverallProgress()
    }
    
    private func updateOverallProgress() {
        let completedCount = Double(files.filter { $0.result != nil }.count)
        let totalCount = Double(files.count)
        updateProgress(totalCount > 0 ? completedCount / totalCount : 0)
    }
    
    func saveConvertedFile(url: URL, originalName: String) async throws {
        logger.debug("💾 Starting save process")
        logger.debug("📂 Source URL: \(url.path)")
        logger.debug("📝 Original name: \(originalName)")
        
        // Verify source file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("❌ Source file does not exist at path: \(url.path)")
            throw ConversionError.fileAccessDenied(path: url.path)
        }
        
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        
        // Get the extension from the source URL
        let sourceExtension = url.pathExtension
        logger.debug("📎 Source extension: \(sourceExtension)")
        
        // Clean up the original filename
        let filenameWithoutExt = (originalName as NSString).deletingPathExtension
        let suggestedFilename = "\(filenameWithoutExt)_converted.\(sourceExtension)"
        
        panel.nameFieldStringValue = suggestedFilename
        panel.message = "Choose where to save the converted file"
        
        // Use the actual file's UTType
        if let fileType = try? UTType(filenameExtension: sourceExtension) {
            panel.allowedContentTypes = [fileType]
            logger.debug("🎯 Setting allowed content type: \(fileType.identifier)")
        }
        
        guard let window = NSApp.windows.first else {
            logger.error("❌ No window found for save panel")
            throw ConversionError.conversionFailed(reason: "No window available")
        }
        
        let response = await panel.beginSheetModal(for: window)
        
        if response == .OK, let saveURL = panel.url {
            logger.debug("✅ Save location selected: \(saveURL.path)")
            
            do {
                try FileManager.default.copyItem(at: url, to: saveURL)
                logger.debug("✅ File saved successfully")
            } catch {
                logger.error("❌ Failed to save file: \(error.localizedDescription)")
                throw ConversionError.exportFailed(reason: error.localizedDescription)
            }
        }
    }
    
    func downloadAllFiles() async throws {
        for file in files {
            if let result = file.result {
                do {
                    try await saveConvertedFile(url: result.outputURL, originalName: file.originalFileName)
                } catch {
                    logger.error("❌ Failed to save file \(file.originalFileName): \(error.localizedDescription)")
                    // Throw the error to propagate it up
                    throw ConversionError.exportFailed(reason: "Failed to save file: \(error.localizedDescription)")
                }
            }
        }
    }
    
    func cancelProcessing() {
        currentTask?.cancel()
        isProcessing = false
        processingResult = nil
        
        // Cancel all individual file processing tasks
        for task in processingTasks.values {
            task.cancel()
        }
        processingTasks.removeAll()
        
        // Reset progress
        progress = 0
        
        // Update file states
        for (index, _) in files.enumerated() where files[index].isProcessing {
            files[index].isProcessing = false
            files[index].error = ConversionError.cancelled
        }
    }
    
    // Add a public method to update progress
    func updateProgress(_ newProgress: Double) {
        progress = newProgress
    }
    
    @MainActor
    func cleanup() {
        Task { @MainActor in
            // Cancel any ongoing processing
            cancelProcessing()
            
            // Clear all files and results
            clearFiles()
            
            // Reset state
            isProcessing = false
            processingResult = nil
            progress = 0
            error = nil
            conversionResult = nil
        }
    }
    
    func processFile(_ url: URL, outputFormat: UTType) async throws -> ProcessingResult {
        let fileState = FileProcessingState(url: url)
        files.append(fileState)
        
        guard let index = files.firstIndex(where: { $0.id == fileState.id }) else {
            throw ConversionError.conversionFailed(reason: "Failed to track file state")
        }
        
        files[index].isProcessing = true
        files[index].progress = 0
        files[index].stage = .analyzing
        isProcessing = true
        
        do {
            let processor = FileProcessor()
            
            let progressObserver = processor.$conversionProgress
                .sink { [weak self] progress in
                    guard let self = self else { return }
                    self.files[index].progress = progress
                    
                    // Update stage based on progress
                    if progress < 0.2 {
                        self.files[index].stage = .analyzing
                    } else if progress < 0.8 {
                        self.files[index].stage = .converting
                    } else if progress < 1.0 {
                        self.files[index].stage = .optimizing
                    }
                    
                    self.updateOverallProgress()
                }
            
            let result = try await processor.processFile(url, outputFormat: outputFormat)
            
            if !Task.isCancelled {
                files[index].result = result
                files[index].progress = 1.0
                files[index].stage = .completed
            }
            
            progressObserver.cancel()
            return result
            
        } catch {
            files[index].error = error
            files[index].stage = .failed
            throw error
        } 
    }
}

struct MultiFileView: View {
    @ObservedObject var processor: MultiFileProcessor
    let supportedTypes: [UTType]
    @State private var hoveredFileId: UUID?
    let onReset: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            // Header with actions
            HStack {
                Text("Files to Convert")
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        processor.clearFiles {
                            onReset()
                        }
                    }
                }) {
                    Text("Clear All")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            // File list
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(processor.files) { file in
                        FileItemView(
                            file: file,
                            targetFormat: processor.selectedOutputFormat,
                            isHovered: hoveredFileId == file.id,
                            onRemove: {
                                if let index = processor.files.firstIndex(where: { $0.id == file.id }) {
                                    processor.removeFile(at: index)
                                }
                            },
                            processor: processor
                        )
                        .onHover { isHovered in
                            hoveredFileId = isHovered ? file.id : nil
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
            )
            
            // Bottom actions
            HStack(spacing: 16) {
                Button(action: {
                    Task {
                        do {
                            try await processor.saveAllFilesToFolder()
                        } catch {
                            logger.error("❌ Failed to save files: \(error.localizedDescription)")
                            // Here you might want to show an error alert to the user
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save All")
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(processor.files.allSatisfy { $0.result == nil })
                
                Spacer()
                
                // Format selector
                Menu {
                    ForEach(supportedTypes, id: \.identifier) { format in
                        Button(action: { processor.selectedOutputFormat = format }) {
                            HStack {
                                Text(format.localizedDescription ?? "Unknown format")
                                if format == processor.selectedOutputFormat {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Convert to: \(String(describing: processor.selectedOutputFormat.localizedDescription))")
                            .font(.system(size: 13))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                
                Button(action: {
                    Task {
                        do {
                            try await processor.downloadAllFiles()
                        } catch {
                            logger.error("❌ Failed to download files: \(error.localizedDescription)")
                            // Here you might want to show an error alert to the user
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Download All")
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(processor.files.allSatisfy { $0.result == nil })
            }
        }
        .padding(20)
    }
}

struct FileItemView: View {
    let file: FileProcessingState
    let targetFormat: UTType
    let isHovered: Bool
    let onRemove: () -> Void
    @ObservedObject var processor: MultiFileProcessor
    @State private var showError = false
    @State private var errorMessage: String?
    
    var body: some View {
        HStack(spacing: 16) {
            // File icon
            Image(systemName: getFileIcon())
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 4) {
                // Filename
                Text(file.displayFileName)
                    .font(.system(size: 13))
                    .lineLimit(1)
                
                // Status
                if file.isProcessing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(height: 2)
                } else if let error = file.error {
                    Text(error.localizedDescription)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                } else if file.result != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Ready to Save")
                            .foregroundColor(.secondary)
                    }
                    .font(.system(size: 12))
                }
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 12) {
                if let result = file.result {
                    Button(action: {
                        Task {
                            do {
                                try await processor.saveConvertedFile(url: result.outputURL, originalName: file.originalFileName)
                            } catch {
                                errorMessage = error.localizedDescription
                                showError = true
                            }
                        }
                    }) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                }
                
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color(NSColor.controlBackgroundColor) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
    }
    
    private func getFileIcon() -> String {
        if let preferredExtension = targetFormat.preferredFilenameExtension,
           file.url.pathExtension.lowercased() == preferredExtension.lowercased() {
            return "doc.circle"
        }
        return "arrow.triangle.2.circlepath"
    }
}
