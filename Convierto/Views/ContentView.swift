import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct FormatSelectorView: View {
    let selectedInputFormat: UTType?
    @Binding var selectedOutputFormat: UTType
    let supportedTypes: [String: [UTType]]
    @State private var showError = false
    @State private var errorMessage: String?
    
    var body: some View {
        HStack(spacing: 20) {
            if let inputFormat = selectedInputFormat {
                InputFormatPill(format: inputFormat)
                
                Image(systemName: "arrow.forward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            
            OutputFormatSelector(
                selectedOutputFormat: $selectedOutputFormat,
                supportedTypes: supportedTypes,
                showError: showError,
                errorMessage: errorMessage
            )
        }
        .onChange(of: selectedOutputFormat) { oldValue, newValue in
            validateFormatCompatibility(input: selectedInputFormat, output: newValue)
        }
    }
    
    private func validateFormatCompatibility(input: UTType?, output: UTType) {
        guard let input = input else { return }
        
        let isCompatible = checkFormatCompatibility(input: input, output: output)
        
        withAnimation(.easeInOut(duration: 0.2)) {
            showError = !isCompatible
            errorMessage = isCompatible ? nil : "Cannot convert between these formats"
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
    @Binding var selectedOutputFormat: UTType
    let supportedTypes: [String: [UTType]]
    let showError: Bool
    let errorMessage: String?
    
    @State private var isHovered = false
    @State private var isMenuOpen = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        Menu {
            ForEach(supportedTypes.keys.sorted(), id: \.self) { category in
                Section {
                    ForEach(supportedTypes[category] ?? [], id: \.identifier) { format in
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedOutputFormat = format
                            }
                        }) {
                            HStack {
                                Image(systemName: getFormatIcon(for: format))
                                    .foregroundColor(format == selectedOutputFormat ? .accentColor : .secondary)
                                    .font(.system(size: 14))
                                Text(format.localizedDescription ?? format.identifier)
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
                } header: {
                    Text(category)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: getFormatIcon(for: selectedOutputFormat))
                    .foregroundStyle(.linearGradient(colors: [.accentColor, .accentColor.opacity(0.8)],
                                                   startPoint: .top,
                                                   endPoint: .bottom))
                    .font(.system(size: 14, weight: .medium))
                
                Text(selectedOutputFormat.localizedDescription ?? selectedOutputFormat.identifier)
                    .font(.system(size: 14, weight: .medium))
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isMenuOpen ? 180 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.8))
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(isHovered ? 0.2 : 0.1), lineWidth: 1)
                }
            )
            .shadow(color: .accentColor.opacity(isHovered ? 0.1 : 0), radius: 8, x: 0, y: 4)
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .menuStyle(BorderlessButtonMenuStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
        .onChange(of: isMenuOpen) { oldValue, newValue in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = newValue
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var processor = MultiFileProcessor()
    @State private var isDragging = false
    @State private var showError = false
    @State private var errorMessage: String?
    @State private var selectedOutputFormat: UTType = .jpeg
    
    let supportedTypes: [String: [UTType]] = [
        "Images": [.jpeg, .tiff, .png, .heic, .gif, .bmp, .webP],
        "Video": [.mpeg4Movie, .quickTimeMovie, .avi],
        "Audio": [.mpeg4Audio, .mp3, .wav, .aiff],
        "Documents": [.pdf]
    ]
    
    var body: some View {
        ZStack {
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
                    VStack(spacing: 32) {
                        // Output format selector
                        OutputFormatSelector(
                            selectedOutputFormat: $selectedOutputFormat,
                            supportedTypes: supportedTypes,
                            showError: showError,
                            errorMessage: errorMessage
                        )
                        .padding(.top, 8)
                        
                        // Drop zone
                        DropZoneView(
                            isDragging: $isDragging,
                            showError: $showError,
                            errorMessage: $errorMessage,
                            selectedFormat: selectedOutputFormat
                        ) { urls in
                            Task {
                                await handleSelectedFiles(urls)
                            }
                        }
                    }
                    .padding(24)
                }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
    }
    
    @MainActor
    private func handleSelectedFiles(_ urls: [URL]) async {
        guard let url = urls.first else { return }
        
        do {
            let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey])
            guard let inputType = resourceValues.contentType else {
                throw ConversionError.invalidInput
            }
            
            // Create a FileProcessor instance
            let fileProcessor = FileProcessor()
            let result = try await fileProcessor.processFile(url, outputFormat: selectedOutputFormat)
            
            withAnimation(.spring(response: 0.3)) {
                processor.isProcessing = false
                processor.processingResult = result
            }
        } catch {
            withAnimation(.easeInOut(duration: 0.2)) {
                errorMessage = error.localizedDescription
                showError = true
            }
            
            // Auto-hide error after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showError = false
                    errorMessage = nil
                }
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

private func checkFormatCompatibility(input: UTType, output: UTType) -> Bool {
    // Define format compatibility rules
    let imageFormats: Set<UTType> = [.jpeg, .png, .tiff, .gif, .heic, .webP]
    let videoFormats: Set<UTType> = [.mpeg4Movie, .quickTimeMovie, .avi]
    let audioFormats: Set<UTType> = [.mp3, .wav, .aiff, .mpeg4Audio]
    
    // PDF special cases
    if input == .pdf && imageFormats.contains(output) {
        return true
    }
    if imageFormats.contains(input) && output == .pdf {
        return true
    }
    
    // Check if formats are in the same category
    if imageFormats.contains(input) && imageFormats.contains(output) {
        return true
    }
    if videoFormats.contains(input) && videoFormats.contains(output) {
        return true
    }
    if audioFormats.contains(input) && audioFormats.contains(output) {
        return true
    }
    
    return false
}