import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FormatSelectorView: View {
    let selectedInputFormat: UTType?
    let selectedOutputFormat: UTType
    let supportedTypes: [String: [UTType]]
    let onOutputFormatSelected: (UTType) -> Void
    
    var body: some View {
        HStack(spacing: 20) {
            if let inputFormat = selectedInputFormat {
                // Input format pill
                InputFormatPill(format: inputFormat)
                
                // Arrow with animation
                Image(systemName: "arrow.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.secondary.opacity(0.8), .secondary.opacity(0.6)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
            
            // Output format selector
            OutputFormatSelector(
                selectedOutputFormat: selectedOutputFormat,
                supportedTypes: supportedTypes,
                onFormatSelected: onOutputFormatSelected
            )
        }
    }
}

struct InputFormatPill: View {
    let format: UTType
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: getFormatIcon(for: format))
                .foregroundStyle(
                    .linearGradient(
                        colors: [.secondary.opacity(0.8), .secondary.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .font(.system(size: 14, weight: .medium))
            
            Text(format.localizedDescription ?? "Unknown Format")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .opacity(0.4)
                
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
            }
        )
    }
}

struct OutputFormatSelector: View {
    let selectedOutputFormat: UTType
    let supportedTypes: [String: [UTType]]
    let onFormatSelected: (UTType) -> Void
    
    @State private var isHovered = false
    @State private var isMenuOpen = false
    
    var body: some View {
        Menu {
            ForEach(supportedTypes.keys.sorted(), id: \.self) { category in
                Section(header: Text(category).foregroundColor(.secondary)) {
                    ForEach(supportedTypes[category] ?? [], id: \.identifier) { format in
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                onFormatSelected(format)
                            }
                        }) {
                            HStack {
                                Image(systemName: getFormatIcon(for: format))
                                    .foregroundColor(format == selectedOutputFormat ? .accentColor : .secondary)
                                    .font(.system(size: 14))
                                Text(format.localizedDescription ?? "Unknown Format")
                                    .font(.system(size: 14))
                                if format == selectedOutputFormat {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                        .font(.system(size: 12, weight: .bold))
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: getFormatIcon(for: selectedOutputFormat))
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .font(.system(size: 14, weight: .medium))
                
                Text(selectedOutputFormat.localizedDescription ?? "Unknown format")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary.opacity(0.9))
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.8))
                    .rotationEffect(.degrees(isMenuOpen ? 180 : 0))
                    .animation(.spring(response: 0.2), value: isMenuOpen)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .opacity(0.4)
                    
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isHovered ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                            lineWidth: 1
                        )
                }
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: isMenuOpen) { oldValue, newValue in
            withAnimation {
                isHovered = newValue
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var processor = MultiFileProcessor()
    @State private var isDragging = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var selectedInputFormat: UTType?
    @State private var selectedOutputFormat: UTType = .jpeg
    @State private var isHovering = false
    
    let supportedTypes: [String: [UTType]] = [
        "Images": [.jpeg, .tiff, .png, .heic, .gif, .bmp, .webP],
        "Video": [.mpeg4Movie, .quickTimeMovie, .avi],
        "Audio": [.mpeg4Audio, .mp3, .wav, .aiff],
        "Documents": [.pdf]
    ]
    
    var body: some View {
        ZStack {
            // Background
            Color(NSColor.windowBackgroundColor)
                .opacity(0.8)
                .ignoresSafeArea()
            
            VStack(spacing: 24) {
                if processor.isProcessing {
                    ProcessingView(progress: processor.progress)
                        .transition(.opacity)
                } else if let result = processor.processingResult {
                    ResultView(result: result) {
                        Task {
                            await processor.saveConvertedFile(url: result.outputURL, originalName: result.originalFileName)
                        }
                    } onReset: {
                        withAnimation(.spring(response: 0.3)) {
                            processor.processingResult = nil
                            processor.progress = 0
                        }
                    }
                    .transition(.opacity)
                } else {
                    // Main conversion interface
                    VStack(spacing: 32) {
                        // Format selector
                        HStack(spacing: 16) {
                            if let inputFormat = selectedInputFormat {
                                FormatPill(format: inputFormat, isInput: true)
                            }
                            
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .opacity(selectedInputFormat != nil ? 1 : 0)
                            
                            OutputFormatSelector(
                                selectedOutputFormat: selectedOutputFormat,
                                supportedTypes: supportedTypes,
                                onFormatSelected: { selectedOutputFormat = $0 }
                            )
                        }
                        .padding(.top, 8)
                        
                        // Drop zone
                        ZStack {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24)
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [
                                                    .accentColor.opacity(isDragging ? 0.3 : 0.1),
                                                    .accentColor.opacity(isDragging ? 0.2 : 0.05)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 1
                                        )
                                )
                                .shadow(
                                    color: .accentColor.opacity(isDragging ? 0.1 : 0),
                                    radius: 8,
                                    y: 4
                                )
                            
                            VStack(spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor.opacity(0.1))
                                        .frame(width: 64, height: 64)
                                    
                                    Image(systemName: isDragging ? "arrow.down.circle.fill" : "square.and.arrow.up.circle.fill")
                                        .font(.system(size: 32, weight: .medium))
                                        .foregroundStyle(
                                            LinearGradient(
                                                colors: [.accentColor, .accentColor.opacity(0.8)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .symbolEffect(.bounce, value: isDragging)
                                }
                                
                                VStack(spacing: 8) {
                                    Text(isDragging ? "Release to Convert" : "Drop Files Here")
                                        .font(.system(size: 16, weight: .medium))
                                    
                                    if !isDragging {
                                        Text("or click to browse")
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(40)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: selectFiles)
                        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers -> Bool in
                            Task { @MainActor in
                                do {
                                    await handleDrop(providers: providers)
                                } catch {
                                    alertMessage = error.localizedDescription
                                    showAlert = true
                                }
                            }
                            return true
                        }
                    }
                    .padding(24)
                }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
        .alert("Conversion Error", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Array(supportedTypes.values.flatMap { $0 })
        
        panel.begin { response in
            if response == .OK {
                Task {
                    await handleSelectedFiles(panel.urls)
                }
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        Task { @MainActor in
            do {
                var urls: [URL] = []
                
                for provider in providers {
                    if provider.canLoadObject(ofClass: URL.self) {
                        if let url = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                            guard FileManager.default.fileExists(atPath: url.path),
                                  FileManager.default.isReadableFile(atPath: url.path) else {
                                throw ConversionError.invalidInput
                            }
                            urls.append(url)
                        }
                    }
                }
                
                guard !urls.isEmpty else { throw ConversionError.invalidInput }
                await handleSelectedFiles(urls)
                
            } catch {
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }
    
    @MainActor
    private func handleSelectedFiles(_ urls: [URL]) async {
        guard let url = urls.first else { return }
        
        do {
            let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
            let type = resourceValues.contentType ?? .item
            
            // Update selected input format
            selectedInputFormat = type
            
            // Find appropriate output format category
            if let category = supportedTypes.first(where: { entry in
                entry.value.contains { type.conforms(to: $0) }
            }) {
                selectedOutputFormat = category.value.first ?? .jpeg
                
                let processor = FileProcessor()
                try await processor.processFile(url, outputFormat: selectedOutputFormat)
                
                if let result = processor.processingResult {
                    withAnimation(.spring(response: 0.3)) {
                        self.processor.processingResult = result
                    }
                }
            } else {
                throw ConversionError.unsupportedFormat
            }
        } catch {
            await MainActor.run {
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }
}

struct FormatPill: View {
    let format: UTType
    let isInput: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: getFormatIcon(for: format))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isInput ? .secondary : .accentColor)
            
            Text(format.localizedDescription ?? "Unknown Format")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.primary.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .opacity(0.4)
                
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
            }
        )
    }
}
func getFormatIcon(for format: UTType) -> String {
    if format.conforms(to: .image) {
        return "photo"
    } else if format.conforms(to: .audiovisualContent) {
        return "film"
    } else if format.conforms(to: .audio) {
        return "music.note"
    }
    return "doc"
}

@MainActor
class FileDropHandler {
    func handleProviders(_ providers: [NSItemProvider], outputFormat: UTType) async throws -> [URL] {
        var urls: [URL] = []
        
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                if let url = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                    guard FileManager.default.fileExists(atPath: url.path),
                          FileManager.default.isReadableFile(atPath: url.path) else {
                        continue
                    }
                    urls.append(url)
                }
            }
        }
        
        guard !urls.isEmpty else { throw ConversionError.invalidInput }
        return urls
    }
}
