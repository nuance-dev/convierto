import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Binding var isDragging: Bool
    @Binding var selectedFormat: UTType
    var onTap: () -> Void
    
    @State private var isHovering = false
    @State private var dragOffset: CGSize = .zero
    @State private var hasDropped = false
    
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
                                    isDragging ? Color.accentColor : Color.secondary.opacity(0.08),
                                    lineWidth: isDragging ? 2 : 1
                                )
                        )
                        .shadow(color: Color.black.opacity(0.03), radius: 20, x: 0, y: 8)
                        .scaleEffect(isDragging ? 0.98 : 1)
                    
                    // Animated gradient background when dragging
                    if isDragging {
                        RoundedRectangle(cornerRadius: 32)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        Color.accentColor.opacity(0.1),
                                        Color.accentColor.opacity(0.05)
                                    ]),
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .opacity(0.8)
                            .transition(.opacity)
                    }
                    
                    VStack(spacing: 24) {
                        // Icon container
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.08))
                                .frame(width: isDragging ? 100 : 88)
                            
                            Circle()
                                .fill(Color.accentColor.opacity(0.05))
                                .frame(width: isDragging ? 88 : 76)
                            
                            Image(systemName: isDragging ? "arrow.down.circle.fill" : "square.and.arrow.up.circle.fill")
                                .font(.system(size: isDragging ? 40 : 36, weight: .medium))
                                .foregroundStyle(.linearGradient(colors: [.accentColor, .accentColor.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                                .symbolEffect(.bounce.up.byLayer, value: isDragging)
                                .shadow(color: .accentColor.opacity(0.2), radius: isDragging ? 10 : 0)
                        }
                        .offset(dragOffset)
                        .animation(.interpolatingSpring(stiffness: 300, damping: 15), value: isDragging)
                        
                        VStack(spacing: 8) {
                            Text(isDragging ? "Release to Convert" : "Drop Files Here")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)
                            
                            Text("or click to browse")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(.secondary)
                                .opacity(isDragging ? 0 : 0.8)
                        }
                        .animation(.easeOut(duration: 0.2), value: isDragging)
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
                Task {
                    await handleDrop(providers: providers)
                }
                return true
            }
            
            // Format indicator pill
            HStack(spacing: 8) {
                Image(systemName: getFormatIcon())
                    .foregroundStyle(.linearGradient(colors: [.accentColor, .accentColor.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                    .font(.system(size: 13, weight: .medium))
                Text("Converting to \(selectedFormat.localizedDescription ?? selectedFormat.identifier)")
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
        .padding(24)
    }
    
    private func handleDrop(providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                do {
                    let url = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL
                    guard let url = url else { throw ConversionError.invalidInput }
                    
                    let processor = FileProcessor()
                    try await processor.processFile(url, outputFormat: selectedFormat)
                } catch {
                    print("Error loading dropped file: \(error)")
                }
            }
        }
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
