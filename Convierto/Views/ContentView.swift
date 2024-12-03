import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var processor = FileProcessor()
    @StateObject private var multiProcessor = MultiFileProcessor()
    @State private var isDragging = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var shouldResize = false
    @State private var maxDimension = "2048"
    
    let supportedTypes: [UTType] = [
        .pdf,      // PDF Documents
        .jpeg,     // JPEG Images
        .tiff,     // TIFF Images
        .png,      // PNG Images
        .heic,     // HEIC Images
        .gif,      // GIF Images
        .bmp,      // BMP Images
        .webP,     // WebP Images
        .svg,      // SVG Images
        .rawImage, // RAW Images
        .ico,      // ICO Images
        .mpeg4Movie,    // MP4 Video
        .movie,         // MOV
        .avi,          // AVI
        .mpeg2Video,   // MPEG-2
        .quickTimeMovie, // QuickTime
        .mpeg4Audio,     // MP4 Audio
        .mp3,          // MP3 Audio
        .wav,          // WAV Audio
        .aiff,         // AIFF Audio
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
                            Text("Compressing File")
                                .font(.system(size: 16, weight: .semibold))
                            Text("This may take a moment...")
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
                            await saveCompressedFile(url: result.compressedURL, originalName: result.fileName)
                        }
                    } onReset: {
                        processor.cleanup()
                    }
                } else if !multiProcessor.files.isEmpty {
                    MultiFileView(
                        processor: multiProcessor,
                        shouldResize: $shouldResize,
                        maxDimension: $maxDimension,
                        supportedTypes: supportedTypes
                    )
                } else {
                    ZStack {
                        DropZoneView(
                            isDragging: $isDragging,
                            shouldResize: $shouldResize,
                            maxDimension: $maxDimension,
                            onTap: selectFiles
                        )
                        
                        Rectangle()
                            .fill(Color.clear)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(isDragging ? Color.accentColor.opacity(0.2) : Color.clear)
                            .onDrop(of: supportedTypes, isTargeted: $isDragging) { providers in
                                handleDrop(providers: providers)
                                return true
                            }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 500)
        .alert("Error", isPresented: $showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = supportedTypes
        panel.allowsMultipleSelection = true
        
        if let window = NSApp.windows.first {
            panel.beginSheetModal(for: window) { response in
                if response == .OK {
                    if panel.urls.count == 1, let url = panel.urls.first {
                        print("📁 Selected single file: \(url.path)")
                        print("📝 Original filename: \(url.lastPathComponent)")
                        handleFileSelection(url: url, originalFilename: url.lastPathComponent)  // Pass originalFilename
                    } else if panel.urls.count > 1 {
                        print("📁 Selected multiple files: \(panel.urls.map { $0.lastPathComponent })")
                        Task { @MainActor in
                            multiProcessor.addFiles(panel.urls)
                        }
                    }
                }
            }
        }
    }
        
        private func handleDrop(providers: [NSItemProvider]) {
            print("🔄 Handling drop with \(providers.count) providers")
            if providers.count == 1 {
                guard let provider = providers.first else { return }
                handleSingleFileDrop(provider: provider)
            } else {
                handleMultiFileDrop(providers: providers)
            }
        }
        
    private func handleSingleFileDrop(provider: NSItemProvider) {
        for type in supportedTypes {
            if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                print("📥 Processing dropped file of type: \(type.identifier)")
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                    guard let url = url else {
                        print("❌ Failed to load dropped file URL")
                        Task { @MainActor in
                            alertMessage = "Failed to load file"
                            showAlert = true
                        }
                        return
                    }
                    
                    print("📄 Original dropped file URL: \(url.path)")
                    let originalFilename = url.lastPathComponent
                    print("📝 Original dropped filename: \(originalFilename)")
                    
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension)
                    
                    print("🔄 Creating temp file at: \(tempURL.path)")
                    
                    do {
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        print("✅ Successfully copied to temp location")
                        
                        Task { @MainActor in
                            handleFileSelection(url: tempURL, originalFilename: originalFilename)  // Pass originalFilename
                        }
                    } catch {
                        print("❌ Failed to copy dropped file: \(error.localizedDescription)")
                        Task { @MainActor in
                            alertMessage = "Failed to process dropped file"
                            showAlert = true
                        }
                    }
                }
                return
            }
        }
    }

    private func handleFileSelection(url: URL, originalFilename: String? = nil) {
        print("🔄 Processing file selection for URL: \(url.path)")
        let filename = originalFilename ?? url.lastPathComponent
        print("📝 Original filename: \(filename)")
        
        Task {
            let dimensionValue = shouldResize ? Double(maxDimension) ?? 2048 : nil
            let settings = CompressionSettings(
                quality: 0.7,
                pngCompressionLevel: 6,
                preserveMetadata: true,
                maxDimension: dimensionValue != nil ? CGFloat(dimensionValue!) : nil,
                optimizeForWeb: true
            )
            
            do {
                try await processor.processFile(url: url, settings: settings, originalFileName: filename)
            } catch {
                print("❌ File processing error: \(error.localizedDescription)")
                await MainActor.run {
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }
        
        private func handleMultiFileDrop(providers: [NSItemProvider]) {
            Task {
                print("📥 Processing multiple dropped files")
                var urls: [URL] = []
                
                for (index, provider) in providers.enumerated() {
                    for type in supportedTypes {
                        if provider.hasItemConformingToTypeIdentifier(type.identifier) {
                            do {
                                let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                                        if let error = error {
                                            print("❌ Error loading file \(index + 1): \(error.localizedDescription)")
                                            continuation.resume(throwing: error)
                                        } else if let url = url {
                                            print("📄 Original file \(index + 1) URL: \(url.path)")
                                            print("📝 Original filename \(index + 1): \(url.lastPathComponent)")
                                            
                                            let originalFileName = url.lastPathComponent
                                            let tempURL = FileManager.default.temporaryDirectory
                                                .appendingPathComponent("\(UUID().uuidString)_\(originalFileName)")
                                            
                                            print("🔄 Creating temp file \(index + 1) at: \(tempURL.path)")
                                            
                                            do {
                                                try FileManager.default.copyItem(at: url, to: tempURL)
                                                print("✅ Successfully copied file \(index + 1) to temp location")
                                                continuation.resume(returning: tempURL)
                                            } catch {
                                                print("❌ Failed to copy file \(index + 1): \(error.localizedDescription)")
                                                continuation.resume(throwing: error)
                                            }
                                        } else {
                                            print("❌ No URL available for file \(index + 1)")
                                            continuation.resume(throwing: NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to load file"]))
                                        }
                                    }
                                }
                                
                                urls.append(url)
                            } catch {
                                print("❌ Failed to process dropped file \(index + 1): \(error.localizedDescription)")
                            }
                            break
                        }
                    }
                }
                
                if !urls.isEmpty {
                    print("✅ Successfully processed \(urls.count) files")
                    print("📁 Temp URLs: \(urls.map { $0.path })")
                    await MainActor.run {
                        multiProcessor.addFiles(urls)
                    }
                }
            }
        }
        
    private func handleFileSelection(url: URL) {
        print("🔄 Processing file selection for URL: \(url.path)")
        print("📝 Original filename: \(url.lastPathComponent)")
        
        Task {
            let dimensionValue = shouldResize ? Double(maxDimension) ?? 2048 : nil
            let settings = CompressionSettings(
                quality: 0.7,
                pngCompressionLevel: 6,
                preserveMetadata: true,
                maxDimension: dimensionValue != nil ? CGFloat(dimensionValue!) : nil,
                optimizeForWeb: true
            )
            
            do {
                // Store original filename before processing
                let originalFileName = url.lastPathComponent
                try await processor.processFile(url: url, settings: settings, originalFileName: originalFileName)
            } catch {
                print("❌ File processing error: \(error.localizedDescription)")
                await MainActor.run {
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }
        
    @MainActor
    func saveCompressedFile(url: URL, originalName: String) async {
        print("💾 Saving compressed file")
        print("📝 Original name: \(originalName)")
        print("📁 Compressed file URL: \(url.path)")
        
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        
        // Extract original filename without UUID
        let originalURL = URL(fileURLWithPath: originalName)
        let filenameWithoutExt = originalURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}\."#,
                                 with: "",
                                 options: .regularExpression)
        let fileExtension = url.pathExtension
        
        let suggestedName = "\(filenameWithoutExt)_compressed.\(fileExtension)"
        print("📝 Suggested save name: \(suggestedName)")
        panel.nameFieldStringValue = suggestedName
        
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension)].compactMap { $0 }
        panel.message = "Choose where to save the compressed file"
        
        guard let window = NSApp.windows.first else { return }
        
        let response = await panel.beginSheetModal(for: window)
        
        if response == .OK, let saveURL = panel.url {
            print("📥 Saving to: \(saveURL.path)")
            do {
                // Check if file exists
                if FileManager.default.fileExists(atPath: saveURL.path) {
                    try FileManager.default.removeItem(at: saveURL)
                }
                
                try FileManager.default.copyItem(at: url, to: saveURL)
                print("✅ File saved successfully")
                processor.cleanup()
            } catch {
                print("❌ Save error: \(error.localizedDescription)")
                alertMessage = "Failed to save file: \(error.localizedDescription)"
                showAlert = true
            }
        } else {
            print("❌ Save cancelled or window not found")
        }
    }
}
