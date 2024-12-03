import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var processor = FileProcessor()
    @StateObject private var multiProcessor = MultiFileProcessor()
    @State private var isDragging = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var selectedInputFormat: UTType?
    @State private var selectedOutputFormat: UTType = .jpeg
    
    let supportedTypes: [String: [UTType]] = [
        "Images": [.jpeg, .tiff, .png, .heic, .gif, .bmp, .webP, .svg, .rawImage],
        "Video": [.mpeg4Movie, .movie, .avi, .mpeg2Video, .quickTimeMovie],
        "Audio": [.mpeg4Audio, .mp3, .wav, .aiff]
    ]
    
    var body: some View {
        ZStack {
            VisualEffectBlur(material: .headerView, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                if processor.isProcessing {
                    // Single file processing view
                    VStack(spacing: 24) {
                        // Progress Circle
                        ZStack {
                            Circle()
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                                .frame(width: 60, height: 60)
                            
                            Circle()
                                .trim(from: 0, to: processor.progress)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .frame(width: 60, height: 60)
                                .rotationEffect(.degrees(-90))
                            
                            Text("\(Int(processor.progress * 100))%")
                                .font(.system(size: 14, weight: .medium))
                        }
                        
                        VStack(spacing: 8) {
                            Text("Converting File")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Almost there...")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: 320)
                    .padding(32)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(NSColor.windowBackgroundColor))
                            .opacity(0.8)
                            .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: 10)
                    )
                } else if let result = processor.processingResult {
                    ResultView(result: result) {
                        Task {
                            await saveConvertedFile(url: result.outputURL, originalName: result.fileName)
                        }
                    } onReset: {
                        processor.cleanup()
                    }
                } else if !multiProcessor.files.isEmpty {
                    MultiFileView(
                        processor: multiProcessor,
                        selectedOutputFormat: $selectedOutputFormat,
                        supportedTypes: supportedTypes.values.flatMap { $0 }
                    )
                } else {
                    VStack(spacing: 24) {
                        // Enhanced Format selector
                        HStack(spacing: 16) {
                            if let inputFormat = selectedInputFormat {
                                // Input format pill
                                HStack {
                                    Image(systemName: getFormatIcon(for: inputFormat))
                                        .foregroundColor(.secondary)
                                    Text(inputFormat.localizedDescription)
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color(NSColor.controlBackgroundColor))
                                        .opacity(0.8)
                                )
                                
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            
                            // Output format selector
                            Menu {
                                ForEach(supportedTypes.keys.sorted(), id: \.self) { category in
                                    Menu(category) {
                                        ForEach(supportedTypes[category] ?? [], id: \.identifier) { format in
                                            Button(action: {
                                                selectedOutputFormat = format
                                            }) {
                                                HStack {
                                                    Text(format.localizedDescription)
                                                    if format == selectedOutputFormat {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: getFormatIcon(for: selectedOutputFormat))
                                        .foregroundColor(.accentColor)
                                    Text(selectedOutputFormat.localizedDescription)
                                        .font(.system(size: 14, weight: .medium))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color(NSColor.controlBackgroundColor))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                                        )
                                )
                            }
                            .menuStyle(BorderlessButtonMenuStyle())
                        }
                        
                        ZStack {
                            DropZoneView(
                                isDragging: $isDragging,
                                selectedFormat: $selectedOutputFormat,
                                onTap: selectFiles
                            )
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 400, minHeight: 300)
        .alert(isPresented: $showAlert) {
            Alert(title: Text("Error"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = supportedTypes.values.flatMap { $0 }
        
        if panel.runModal() == .OK {
            handleSelectedFiles(panel.urls)
        }
    }
    
    private func handleSelectedFiles(_ urls: [URL]) {
        if urls.count > 1 {
            multiProcessor.addFiles(urls)
        } else if let url = urls.first {
            Task {
                await processor.processFile(url, outputFormat: selectedOutputFormat)
            }
        }
    }
    
    private func saveConvertedFile(url: URL, originalName: String) async {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = originalName
        savePanel.allowedContentTypes = [selectedOutputFormat]
        
        if savePanel.runModal() == .OK {
            guard let destinationURL = savePanel.url else { return }
            do {
                try FileManager.default.moveItem(at: url, to: destinationURL)
            } catch {
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }
    
    private func getFormatIcon(for format: UTType) -> String {
        if format.conforms(to: .image) {
            return "photo"
        } else if format.conforms(to: .audiovisualContent) {
            return "film"
        } else if format.conforms(to: .audio) {
            return "music.note"
        }
        return "doc"
    }
}
