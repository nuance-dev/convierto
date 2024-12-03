import SwiftUI

struct ResultView: View {
    let result: FileProcessor.ProcessingResult
    let onDownload: () -> Void
    let onReset: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            // Status Icon
            ZStack {
                Circle()
                    .fill(Color(NSColor.windowBackgroundColor))
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
                
                Image(systemName: result.savedPercentage > 0 ? "checkmark" : "exclamationmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(result.savedPercentage > 0 ? .green : .orange)
            }
            
            // Status Text
            VStack(spacing: 8) {
                Text(result.savedPercentage > 0 ? "Compression Complete" : "Already Optimized")
                    .font(.system(size: 16, weight: .semibold))
                
                if result.savedPercentage > 0 {
                    Text("File size reduced by \(result.savedPercentage)%")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                } else {
                    Text("No further compression needed")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            
            // File Size Info
            HStack(spacing: 32) {
                VStack(spacing: 4) {
                    Text("Original")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(formatFileSize(result.originalSize))
                        .font(.system(size: 14, weight: .medium))
                }
                
                VStack(spacing: 4) {
                    Text("Compressed")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(formatFileSize(result.compressedSize))
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .opacity(0.5)
            )
            
            // Action Buttons
            HStack(spacing: 12) {
                Button(action: onReset) {
                    Text("New File")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(SecondaryButtonStyle())
                
                Button(action: onDownload) {
                    Text("Save")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(NSColor.windowBackgroundColor))
                .opacity(0.8)
                .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: 10)
        )
    }
    
    private func formatFileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// Add new custom button styles
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .background(Color.accentColor)
            .cornerRadius(8)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}
