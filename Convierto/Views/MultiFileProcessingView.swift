import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct FileProcessingState: Identifiable {
    let id: UUID
    let url: URL
    let originalFileName: String
    var progress: Double
    var result: ProcessingResult?
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
    @Published var selectedOutputFormat: UTType = .jpeg
    @Published var progress: Double = 0
    @Published var isProcessing: Bool = false
    @Published var processingResult: ProcessingResult?
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
    }
    
    func saveAllFilesToFolder() async {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose where to save all converted files"
        panel.prompt = "Select Folder"
        
        guard let window = NSApp.windows.first else { return }
        let response = await panel.beginSheetModal(for: window)
        
        if response == .OK, let folderURL = panel.url {
            for file in files {
                if let result = file.result {
                    do {
                        let destinationURL = folderURL.appendingPathComponent(result.suggestedFileName)
                        try FileManager.default.copyItem(at: result.outputURL, to: destinationURL)
                    } catch {
                        print("Failed to save file \(file.originalFileName): \(error.localizedDescription)")
                    }
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
        
        do {
            let processor = FileProcessor()
            let result = try await processor.processFile(fileState.url, outputFormat: selectedOutputFormat)
            
            if !Task.isCancelled {
                files[index].result = result
                files[index].progress = 1.0
            }
        } catch {
            files[index].error = error
        }
        
        files[index].isProcessing = false
        isProcessing = files.contains(where: { $0.isProcessing })
        progress = Double(files.filter { $0.result != nil }.count) / Double(files.count)
    }
    
    func saveConvertedFile(url: URL, originalName: String) async {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        
        // Get the correct extension for the current format
        let newExtension = selectedOutputFormat.preferredFilenameExtension ?? "converted"
        let filenameWithoutExt = URL(fileURLWithPath: originalName).deletingPathExtension().lastPathComponent
        let suggestedFilename = "\(filenameWithoutExt)_converted.\(newExtension)"
        
        panel.nameFieldStringValue = suggestedFilename
        panel.message = "Choose where to save the converted file"
        panel.allowedContentTypes = [selectedOutputFormat]
        
        guard let window = NSApp.windows.first else { return }
        
        let response = await panel.beginSheetModal(for: window)
        
        if response == .OK, let saveURL = panel.url {
            do {
                if FileManager.default.fileExists(atPath: saveURL.path) {
                    try FileManager.default.removeItem(at: saveURL)
                }
                
                // Ensure correct extension on the output file
                let finalURL = saveURL.deletingPathExtension().appendingPathExtension(newExtension)
                try FileManager.default.copyItem(at: url, to: finalURL)
            } catch {
                print("Failed to save file: \(error.localizedDescription)")
            }
        }
    }
    
    func downloadAllFiles() async {
        for file in files {
            if let result = file.result {
                await saveConvertedFile(url: result.outputURL, originalName: file.originalFileName)
            }
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
                        await processor.downloadAllFiles()
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
                            await processor.saveConvertedFile(url: result.outputURL, originalName: file.originalFileName)
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
    }
    
    private func getFileIcon() -> String {
        if let preferredExtension = targetFormat.preferredFilenameExtension,
           file.url.pathExtension.lowercased() == preferredExtension.lowercased() {
            return "doc.circle"
        }
        return "arrow.triangle.2.circlepath"
    }
}
