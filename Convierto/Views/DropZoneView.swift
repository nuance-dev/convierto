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
    
    private let dropDelegate: FileDropDelegate
    
    init(isDragging: Binding<Bool>, showError: Binding<Bool>, errorMessage: Binding<String?>, selectedFormat: UTType, onFilesSelected: @escaping ([URL]) -> Void) {
        self._isDragging = isDragging
        self._showError = showError
        self._errorMessage = errorMessage
        self.selectedFormat = selectedFormat
        self.onFilesSelected = onFilesSelected
        
        self.dropDelegate = FileDropDelegate(
            isDragging: isDragging,
            supportedTypes: [.fileURL],
            handleDrop: { providers in
                Task {
                    do {
                        let handler = FileDropHandler()
                        let urls = try await handler.handleProviders(providers, outputFormat: selectedFormat)
                        onFilesSelected(urls)
                        
                        await MainActor.run {
                            withAnimation {
                                showError.wrappedValue = false
                                errorMessage.wrappedValue = nil
                            }
                        }
                    } catch {
                        logger.error("Drop handling failed: \(error.localizedDescription)")
                        await MainActor.run {
                            withAnimation {
                                errorMessage.wrappedValue = error.localizedDescription
                                showError.wrappedValue = true
                            }
                        }
                        
                        // Auto-hide error after 3 seconds
                        try? await Task.sleep(for: .seconds(3))
                        await MainActor.run {
                            withAnimation {
                                showError.wrappedValue = false
                                errorMessage.wrappedValue = nil
                            }
                        }
                    }
                }
            }
        )
    }
    
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
            
            VStack(spacing: 16) {
                // Drop zone content
                DropZoneContent(
                    isDragging: isDragging,
                    showError: showError,
                    errorMessage: errorMessage
                )
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: selectFiles)
        .onDrop(of: [.fileURL], delegate: dropDelegate)
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .movie, .audio, .pdf]
        
        Task { @MainActor in
            guard let window = NSApp.windows.first else { return }
            let response = await panel.beginSheetModal(for: window)
            
            if response == .OK {
                onFilesSelected(panel.urls)
            }
        }
    }
}

private struct DropZoneContent: View {
    let isDragging: Bool
    let showError: Bool
    let errorMessage: String?
    
    var body: some View {
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
    }
}