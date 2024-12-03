import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct FileProcessingState: Identifiable {
    let id: UUID
    let url: URL
    let originalFileName: String
    var progress: Double
    var result: FileProcessor.ProcessingResult?
    var isProcessing: Bool
    var error: Error?
    
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
    }
}

@MainActor
class MultiFileProcessor: ObservableObject {
    @Published private(set) var files: [FileProcessingState] = []
    @Published private(set) var isProcessingMultiple = false
    private var processingTasks: [UUID: Task<Void, Never>] = [:]
    
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
    
    func clearFiles() {
        // Cancel all ongoing processing tasks
        for task in processingTasks.values {
            task.cancel()
        }
        processingTasks.removeAll()
        files.removeAll()
    }
    
    private func processFile(with id: UUID) {
        let task = Task {
            await processFileInternal(with: id)
        }
        processingTasks[id] = task
    }
    
    func saveAllFilesToFolder() async {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose where to save all compressed files"
        panel.prompt = "Select Folder"
        
        guard let window = NSApp.windows.first else { return }
        let response = await panel.beginSheetModal(for: window)
        
        if response == .OK, let folderURL = panel.url {
            for file in files {
                if let result = file.result {
                    do {
                        // Use the original filename instead of the result filename
                        let originalURL = URL(fileURLWithPath: file.originalFileName)
                        let filenameWithoutExt = originalURL.deletingPathExtension().lastPathComponent
                        let fileExtension = originalURL.pathExtension
                        let newFileName = "\(filenameWithoutExt)_compressed.\(fileExtension)"
                        let destinationURL = folderURL.appendingPathComponent(newFileName)
                        
                        try FileManager.default.copyItem(at: result.compressedURL, to: destinationURL)
                    } catch {
                        print("Failed to save file \(file.originalFileName): \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func processFileInternal(with id: UUID) async {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        guard index < files.count else { return }
        
        let processor = FileProcessor()
        
        // Update the processing state
        files[index].isProcessing = true
        
        do {
            let settings = CompressionSettings(
                quality: 0.7,
                pngCompressionLevel: 6,
                preserveMetadata: true,
                optimizeForWeb: true
            )
            
            try await processor.processFile(url: files[index].url, settings: settings)
            
            guard index < files.count, files[index].id == id else { return }
            
            if let processingResult = processor.processingResult {
                files[index].result = processingResult
                files[index].isProcessing = false
            }
        } catch {
            guard index < files.count, files[index].id == id else { return }
            files[index].error = error
            files[index].isProcessing = false
        }
        
        // Clean up the task
        processingTasks.removeValue(forKey: id)
    }
    
    func saveCompressedFile(url: URL, originalName: String) async {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        
        // Use originalName directly instead of extracting from URL
        let originalURL = URL(fileURLWithPath: originalName)
        let filenameWithoutExt = originalURL.deletingPathExtension().lastPathComponent
        let fileExtension = originalURL.pathExtension
        panel.nameFieldStringValue = "\(filenameWithoutExt)_compressed.\(fileExtension)"
        
        panel.allowedContentTypes = [UTType(filenameExtension: url.pathExtension)].compactMap { $0 }
        panel.message = "Choose where to save the compressed file"
        
        guard let window = NSApp.windows.first else { return }
        
        let response = await panel.beginSheetModal(for: window)
        
        if response == .OK, let saveURL = panel.url {
            do {
                // Check if file exists
                if FileManager.default.fileExists(atPath: saveURL.path) {
                    try FileManager.default.removeItem(at: saveURL)
                }
                
                try FileManager.default.copyItem(at: url, to: saveURL)
            } catch {
                print("Failed to save file: \(error.localizedDescription)")
            }
        }
    }
    
    func downloadAllFiles() async {
        for file in files {
            if let result = file.result {
                await saveCompressedFile(url: result.compressedURL, originalName: file.originalFileName)
            }
        }
    }
}

struct MultiFileView: View {
    @ObservedObject var processor: MultiFileProcessor
    @Binding var shouldResize: Bool
    @Binding var maxDimension: String
    let supportedTypes: [UTType]
    @State private var hoveredFileID: UUID?
    
    init(processor: MultiFileProcessor, shouldResize: Binding<Bool>, maxDimension: Binding<String>, supportedTypes: [UTType]) {
        self._processor = ObservedObject(wrappedValue: processor)
        self._shouldResize = shouldResize
        self._maxDimension = maxDimension
        self.supportedTypes = supportedTypes
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Header section with ButtonGroup
            HStack {
                Text("Files")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if !processor.files.isEmpty {
                    ButtonGroup(buttons: [
                        (
                            title: "Save All",
                            icon: "folder.fill.badge.plus",
                            action: {
                                Task {
                                    await processor.saveAllFilesToFolder()
                                }
                            }
                        ),
                        (
                            title: "Clear All",
                            icon: "trash.fill",
                            action: {
                                processor.clearFiles()
                            }
                        )
                    ])
                }
            }
            .padding(.horizontal)
            
            // File list
            VStack(spacing: 0) { // Wrapper for consistent padding
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(processor.files.enumerated()), id: \.element.id) { index, file in
                            FileRow(
                                file: file,
                                isHovered: hoveredFileID == file.id,
                                onSave: {
                                    if let result = file.result {
                                        Task {
                                            await processor.saveCompressedFile(
                                                url: result.compressedURL,
                                                originalName: file.originalFileName
                                            )
                                        }
                                    }
                                },
                                onRemove: {
                                    processor.removeFile(at: index)
                                }
                            )
                            .onHover { isHovered in
                                hoveredFileID = isHovered ? file.id : nil
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical) // Add vertical padding inside scroll view
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding()
    }
}

struct FileRow: View {
    let file: FileProcessingState
    let isHovered: Bool
    let onSave: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            // File icon with extension badge
            ZStack(alignment: .bottomTrailing) {
                getFileIcon(for: file.url.pathExtension.lowercased())
                    .font(.system(size: 28))
                
                Text(file.url.pathExtension.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            
            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(file.displayFileName)
                    .font(.headline)
                    .lineLimit(1)
                
                Group {
                    if let result = file.result {
                        Label(
                            "Reduced by \(result.savedPercentage)%",
                            systemImage: "arrow.down.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else if let error = file.error {
                        Label(
                            error.localizedDescription,
                            systemImage: "exclamationmark.circle.fill"
                        )
                        .foregroundStyle(.red)
                    } else if file.isProcessing {
                        Label(
                            "Processing...",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .foregroundStyle(.blue)
                    }
                }
                .font(.subheadline)
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 12) {
                if file.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else if let _ = file.result {
                    Button(action: onSave) {
                        Label("Download", systemImage: "square.and.arrow.down.fill")
                    }
                    .buttonStyle(GlassButtonStyle())
                }
                
                Button(action: onRemove) {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .opacity(isHovered ? 1 : 0.7)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color(NSColor.controlBackgroundColor).opacity(0.7) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
    }
    
    @ViewBuilder
    private func getFileIcon(for extension: String) -> some View {
        switch `extension` {
        case "jpg", "jpeg", "png", "heic", "webp":
            Image(systemName: "photo.fill")
                .foregroundStyle(.blue)
        case "mp4", "mov", "avi":
            Image(systemName: "video.fill")
                .foregroundStyle(.purple)
        case "mp3", "wav", "aiff":
            Image(systemName: "music.note")
                .foregroundStyle(.pink)
        case "pdf":
            Image(systemName: "doc.fill")
                .foregroundStyle(.red)
        default:
            Image(systemName: "doc.fill")
                .foregroundStyle(.secondary)
        }
    }
}
