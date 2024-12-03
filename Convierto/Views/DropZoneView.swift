import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
    category: "DropZone"
)

struct DropZoneView: View {
    @Binding var isDragging: Bool
    @Binding var showError: Bool
    @Binding var errorMessage: String?
    let selectedFormat: UTType
    let onFilesSelected: ([URL]) -> Void
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(
                            LinearGradient(
                                colors: showError ? 
                                    [.red.opacity(0.3), .red.opacity(0.2)] :
                                    isDragging ? 
                                        [.accentColor.opacity(0.3), .accentColor.opacity(0.2)] :
                                        [.secondary.opacity(0.1), .secondary.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: isDragging || showError ? 2 : 1
                        )
                )
                .shadow(
                    color: showError ? .red.opacity(0.1) :
                        isDragging ? .accentColor.opacity(0.1) : .clear,
                    radius: 8,
                    y: 4
                )
            
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(showError ? Color.red.opacity(0.1) : Color.accentColor.opacity(0.1))
                        .frame(width: 64, height: 64)
                    
                    Image(systemName: showError ? "exclamationmark.circle.fill" :
                            isDragging ? "arrow.down.circle.fill" : "square.and.arrow.up.circle.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: showError ? [.red, .red.opacity(0.8)] :
                                    [.accentColor, .accentColor.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .symbolEffect(.bounce, value: isDragging)
                }
                
                VStack(spacing: 8) {
                    Text(showError ? (errorMessage ?? "Error") :
                            isDragging ? "Release to Convert" : "Drop Files Here")
                        .font(.system(size: 16, weight: .medium))
                    
                    if !isDragging && !showError {
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
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            Task {
                do {
                    let urls = try await handleDrop(providers: providers)
                    onFilesSelected(urls)
                    withAnimation {
                        showError = false
                        errorMessage = nil
                    }
                } catch {
                    withAnimation {
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
            return true
        }
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        panel.begin { response in
            if response == .OK {
                onFilesSelected(panel.urls)
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) async throws -> [URL] {
        var urls: [URL] = []
        
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                do {
                    let url = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL
                    if let url = url {
                        // Verify file exists and is readable
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            logger.error("File does not exist: \(url.path)")
                            continue
                        }
                        
                        urls.append(url)
                    }
                } catch {
                    logger.error("Failed to load URL from provider: \(error.localizedDescription)")
                    continue
                }
            }
        }
        
        guard !urls.isEmpty else {
            throw ConversionError.invalidInput
        }
        
        return urls
    }
}
