import SwiftUI

struct ResultView: View {
    let result: ProcessingResult
    let onDownload: () -> Void
    let onReset: () -> Void
    @State private var isHovering = false
    @State private var showCopied = false
    @State private var showError = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(spacing: 32) {
            // Success icon
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            
            // Status text
            VStack(spacing: 8) {
                Text("Conversion Complete")
                    .font(.system(size: 16, weight: .medium))
                
                Text("Ready to save")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            
            // File info card
            VStack(spacing: 16) {
                HStack {
                    Text("File Details")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                }
                
                VStack(spacing: 12) {
                    InfoRow(
                        title: "Original",
                        value: result.originalFileName,
                        icon: "doc"
                    )
                    
                    Divider()
                        .opacity(0.5)
                    
                    InfoRow(
                        title: "Converted",
                        value: result.suggestedFileName,
                        icon: "doc.fill"
                    )
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .opacity(0.5)
                )
            }
            .padding(.horizontal)
            
            // Action buttons
            HStack(spacing: 12) {
                Button(action: {
                    withAnimation(.spring(response: 0.3)) {
                        onReset()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Convert Another")
                    }
                    .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                
                Button(action: {
                    Task {
                        do {
                            // Verify file exists and is accessible
                            guard FileManager.default.fileExists(atPath: result.outputURL.path),
                                  FileManager.default.isReadableFile(atPath: result.outputURL.path) else {
                                throw ConversionError.exportFailed(reason: "The converted file is no longer accessible")
                            }
                            
                            // Create a temporary copy before saving
                            let tempURL = try FileManager.default.url(
                                for: .itemReplacementDirectory,
                                in: .userDomainMask,
                                appropriateFor: result.outputURL,
                                create: true
                            ).appendingPathComponent(result.suggestedFileName)
                            
                            try FileManager.default.copyItem(at: result.outputURL, to: tempURL)
                            
                            // Update the result with the new temporary URL
                            _ = ProcessingResult(
                                outputURL: tempURL,
                                originalFileName: result.originalFileName,
                                suggestedFileName: result.suggestedFileName,
                                fileType: result.fileType,
                                metadata: result.metadata
                            )
                            
                            // Perform the save operation
                            withAnimation(.spring(response: 0.3)) {
                                onDownload()
                            }
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save File")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [.accentColor, .accentColor.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .shadow(color: .accentColor.opacity(0.2), radius: 8, y: 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    let icon: String
    @State private var isHovering = false
    @State private var showCopied = false
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            
            Spacer()
            
            if isHovering {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    
                    withAnimation {
                        showCopied = true
                    }
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation {
                            showCopied = false
                        }
                    }
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}
