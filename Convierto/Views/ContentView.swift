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
    
    @State private var isMenuOpen = false
    @State private var isHovered = false
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            // Selector Button
            Button {
                withAnimation(.spring(response: 0.3)) {
                    isMenuOpen.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Selected Format Icon
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: getFormatIcon(for: selectedOutputFormat))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.accentColor, .accentColor.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Convert to")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(selectedOutputFormat.localizedDescription ?? "Select Format")
                            .font(.system(size: 14, weight: .medium))
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isMenuOpen ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(colorScheme == .dark ? 
                                Color.black.opacity(0.3) : 
                                Color.white.opacity(0.8))
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.accentColor.opacity(isHovered ? 0.2 : 0.1), 
                                   lineWidth: 1)
                    }
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isHovered = hovering
                }
            }
            
            // Format Menu (expands below)
            if isMenuOpen {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(supportedTypes.keys.sorted(), id: \.self) { category in
                            // Category Header
                            Text(category)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 16)
                            
                            // Format Grid
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 8) {
                                ForEach(supportedTypes[category] ?? [], id: \.identifier) { format in
                                    FormatButton(
                                        format: format,
                                        isSelected: format == selectedOutputFormat,
                                        action: {
                                            withAnimation(.spring(response: 0.3)) {
                                                selectedOutputFormat = format
                                                isMenuOpen = false
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .frame(maxHeight: 300)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(colorScheme == .dark ? 
                            Color.black.opacity(0.3) : 
                            Color.white.opacity(0.8))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if showError {
                Text(errorMessage ?? "Error")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.1))
                    )
                    .offset(y: -30)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }
    
    func getFormatIcon(for format: UTType) -> String {
        FormatSelectorMenu.getFormatIcon(for: format)
    }
}

struct ContentView: View {
    @StateObject private var processor = MultiFileProcessor()
    @State private var isDragging = false
    @State private var showError = false
    @State private var errorMessage: String?
    @State private var selectedOutputFormat: UTType = .jpeg
    @State private var isMultiFileMode = false
    @State private var isFormatSelectorPresented = false
    
    private let supportedTypes: [UTType] = Array(Set([
        .jpeg, .png, .heic, .tiff, .gif, .bmp, .webP,
        .mpeg4Movie, .quickTimeMovie, .avi,
        .mp3, .wav, .aiff, .m4a, .aac,
        .pdf
    ])).sorted { $0.identifier < $1.identifier }
    
    private func supportedFormats(for operation: String) -> [String: [UTType]] {
        let formats: [String: [UTType]] = [
            "Images": [
                UTType.jpeg,
                UTType.png,
                UTType.heic,
                UTType.tiff,
                UTType.gif,
                UTType.bmp,
                UTType.webP
            ],
            "Documents": [UTType.pdf],
            "Video": [
                UTType.mpeg4Movie,
                UTType.quickTimeMovie,
                UTType.avi
            ],
            "Audio": [
                UTType.mp3,
                UTType.wav,
                UTType.aiff,
                UTType.m4a,
                UTType.aac
            ]
        ]
        return formats
    }
    
    private var categorizedTypes: [String: [UTType]] {
        Dictionary(grouping: supportedTypes) { type in
            if type.conforms(to: .image) {
                return "Images"
            } else if type.conforms(to: .audio) {
                return "Audio"
            } else if type.conforms(to: .video) {
                return "Video"
            } else if type.conforms(to: .text) {
                return "Documents"
            } else {
                return "Other"
            }
        }
    }
    
    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .opacity(0.8)
                .ignoresSafeArea()
            
            VStack(spacing: 10) {
                if isMultiFileMode {
                    MultiFileView(
                        processor: processor,
                        supportedTypes: supportedTypes,
                        onReset: {
                            withAnimation(.spring(response: 0.3)) {
                                isMultiFileMode = false
                                processor.processingResult = nil
                            }
                        }
                    )
                    .transition(.opacity)
                } else if processor.isProcessing {
                    ProcessingView(onCancel: {
                        processor.cancelProcessing()
                        withAnimation(.spring(response: 0.3)) {
                            processor.isProcessing = false
                            processor.processingResult = nil
                        }
                    })
                    .transition(.opacity)
                } else if let result = processor.processingResult {
                    ResultView(result: result) {
                        Task {
                            do {
                                try await processor.saveConvertedFile(url: result.outputURL, originalName: result.originalFileName)
                                processor.cleanup()
                            } catch {
                                withAnimation(.spring(response: 0.3)) {
                                    errorMessage = error.localizedDescription
                                    showError = true
                                }
                            }
                        }
                    } onReset: {
                        withAnimation(.spring(response: 0.3)) {
                            processor.cleanup()
                            processor.processingResult = nil
                            processor.progress = 0
                            isMultiFileMode = false
                        }
                    }
                    .transition(.opacity)
                } else {
                    VStack(spacing: 4) {
                        FormatSelectorView(
                            selectedInputFormat: nil,
                            selectedOutputFormat: $selectedOutputFormat,
                            supportedTypes: supportedFormats(for: "output")
                        )
                        .padding(.top, 8)
                        
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
            
            // Format selector overlay at root level
            if isFormatSelectorPresented {
                FormatSelectorMenu(
                    selectedFormat: $selectedOutputFormat,
                    supportedTypes: categorizedTypes,
                    isPresented: $isFormatSelectorPresented
                )
                .transition(.opacity)
            }
        }
    }
    
    @MainActor
    private func handleSelectedFiles(_ urls: [URL]) async {
        if urls.count > 1 {
            withAnimation(.spring(response: 0.3)) {
                isMultiFileMode = true
                processor.clearFiles()
                processor.selectedOutputFormat = selectedOutputFormat
            }
            
            for url in urls {
                do {
                    _ = try await processor.processFile(url, outputFormat: selectedOutputFormat)
                } catch {
                    withAnimation(.spring(response: 0.3)) {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        } else if let url = urls.first {
            do {
                let resourceValues = try url.resourceValues(forKeys: [.contentTypeKey])
                guard let inputType = resourceValues.contentType else {
                    throw ConversionError.invalidInput
                }
                
                // Validate input type
                let allSupportedTypes = supportedFormats(for: "input").values.flatMap { $0 }
                guard allSupportedTypes.contains(where: { inputType.conforms(to: $0) }) else {
                    throw ConversionError.unsupportedFormat(format: inputType)
                }
                
                withAnimation {
                    processor.isProcessing = true
                }
                
                do {
                    let result = try await processor.processFile(url, outputFormat: selectedOutputFormat)
                    
                    withAnimation(.spring(response: 0.3)) {
                        processor.isProcessing = false
                        processor.processingResult = result
                    }
                } catch {
                    withAnimation(.spring(response: 0.3)) {
                        processor.isProcessing = false
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            } catch {
                withAnimation(.easeInOut(duration: 0.2)) {
                    errorMessage = error.localizedDescription
                    showError = true
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
    if format.isImageFormat {
        return "photo"
    } else if format.isVideoFormat {
        return "film"
    } else if format.isAudioFormat {
        return "waveform"
    } else if format.isPDFFormat {
        return "doc"
    } else {
        return "doc.fill"
    }
}

private func checkFormatCompatibility(input: UTType, output: UTType) -> Bool {
    // Define format categories
    let imageFormats: Set<UTType> = [.jpeg, .png, .tiff, .gif, .heic, .webP, .bmp]
    let videoFormats: Set<UTType> = [.mpeg4Movie, .quickTimeMovie, .avi]
    let audioFormats: Set<UTType> = [.mp3, .wav, .aiff, .m4a, .aac]
    
    // Enhanced cross-format conversion support
    switch (input, output) {
    // PDF conversions
    case (.pdf, _) where imageFormats.contains(output):
        return true
    case (_, .pdf) where imageFormats.contains(input):
        return true
        
    // Audio-Video conversions
    case (let i, let o) where i.conforms(to: .audio) && o.conforms(to: .audiovisualContent):
        return true
    case (let i, let o) where i.conforms(to: .audiovisualContent) && o.conforms(to: .audio):
        return true
        
    // Image-Video conversions
    case (let i, let o) where i.conforms(to: .image) && o.conforms(to: .audiovisualContent):
        return true
    case (let i, let o) where i.conforms(to: .audiovisualContent) && o.conforms(to: .image):
        return true
        
    // Image sequence to video
    case (let i, let o) where imageFormats.contains(i) && videoFormats.contains(o):
        return true
        
    // Video to image sequence
    case (let i, let o) where videoFormats.contains(i) && imageFormats.contains(o):
        return true
        
    // Audio visualization
    case (let i, let o) where audioFormats.contains(i) && (videoFormats.contains(o) || imageFormats.contains(o)):
        return true
        
    // Same category conversions
    case (let i, let o) where i.conforms(to: .image) && o.conforms(to: .image):
        return true
    case (let i, let o) where i.conforms(to: .audio) && o.conforms(to: .audio):
        return true
    case (let i, let o) where i.conforms(to: .audiovisualContent) && o.conforms(to: .audiovisualContent):
        return true
        
    default:
        return false
    }
}
