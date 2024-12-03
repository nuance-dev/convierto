import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Binding var isDragging: Bool
    @State private var isHovering = false
    @State private var showError = false
    @State private var errorMessage: String?
    @State private var processingResult: ProcessingResult?
    let selectedFormat: UTType
    let onTap: () -> Void
    
    enum DropZoneError: LocalizedError {
        case invalidInput(String)
        case fileAccessDenied(String)
        case processingFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .invalidInput(let message),
                 .fileAccessDenied(let message),
                 .processingFailed(let message):
                return message
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) async throws {
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else {
                throw DropZoneError.invalidInput("This file type isn't supported")
            }
            
            guard let url = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL else {
                throw DropZoneError.invalidInput("Unable to access this file")
            }
            
            // Create security-scoped bookmark
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            var isStale = false
            guard let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                throw DropZoneError.fileAccessDenied("Please allow access to this file")
            }
            
            // Start accessing the security-scoped resource
            let hasAccess = resolvedURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
            }
            
            if hasAccess {
                let processor = FileProcessor()
                try await processor.processFile(resolvedURL, outputFormat: selectedFormat)
                
                if let result = processor.processingResult {
                    await MainActor.run {
                        self.processingResult = result
                        self.showError = false
                        self.errorMessage = nil
                    }
                }
            } else {
                throw DropZoneError.fileAccessDenied("Unable to access this file")
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geometry in
                ZStack {
                    // Background layers
                    RoundedRectangle(cornerRadius: 32)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.2))
                        .overlay(
                            RoundedRectangle(cornerRadius: 32)
                                .strokeBorder(
                                    showError ? Color.red.opacity(0.5) :
                                        isDragging ? Color.accentColor : Color.secondary.opacity(0.08),
                                    lineWidth: isDragging || showError ? 2 : 1
                                )
                        )
                        .shadow(color: Color.black.opacity(0.03), radius: 20, x: 0, y: 8)
                        .scaleEffect(isDragging ? 0.98 : 1)
                    
                    VStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.05))
                            .frame(width: isDragging ? 88 : 76)
                        
                        Image(systemName: showError ? "exclamationmark.circle.fill" :
                                isDragging ? "arrow.down.circle.fill" : "square.and.arrow.up.circle.fill")
                            .font(.system(size: isDragging ? 40 : 36, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: showError ? [.red, .red.opacity(0.8)] :
                                        [.accentColor, .accentColor.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .symbolEffect(.bounce.up.byLayer, value: isDragging)
                        
                        if showError {
                            Text(errorMessage ?? "Error processing file")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                                .transition(.opacity)
                        } else {
                            VStack(spacing: 8) {
                                Text(isDragging ? "Release to Convert" : "Drop Files Here")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                                
                                Text("or click to browse")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(.secondary)
                                    .opacity(isDragging ? 0 : 0.8)
                            }
                        }
                    }
                    .padding(40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers -> Bool in
                Task { @MainActor in
                    do {
                        try await handleDrop(providers: providers)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showError = false
                            errorMessage = nil
                        }
                    } catch {
                        let errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.errorMessage = errorMessage
                            self.showError = true
                        }
                        
                        // Auto-hide error after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                self.showError = false
                                self.errorMessage = nil
                            }
                        }
                    }
                }
                return true
            }
            .animation(.easeInOut(duration: 0.2), value: showError)
            
            // Format indicator pill
            if !showError {
                HStack(spacing: 8) {
                    Image(systemName: getFormatIcon())
                        .foregroundStyle(.linearGradient(colors: [.accentColor, .accentColor.opacity(0.8)],
                                                       startPoint: .top,
                                                       endPoint: .bottom))
                        .font(.system(size: 13, weight: .medium))
                    Text("Convert to \(selectedFormat.localizedDescription ?? "new format")")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
                        .shadow(color: .black.opacity(0.03), radius: 8, x: 0, y: 2)
                )
            }
        }
        .padding(24)
    }
    
    private func getFormatIcon() -> String {
        if selectedFormat.conforms(to: .image) {
            return "photo.fill"
        } else if selectedFormat.conforms(to: .audiovisualContent) {
            return "film.fill"
        } else if selectedFormat.conforms(to: .audio) {
            return "waveform"
        }
        return "doc.fill"
    }
}
