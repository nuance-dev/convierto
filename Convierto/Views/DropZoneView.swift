import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Binding var isDragging: Bool
    @Binding var selectedFormat: UTType
    var onTap: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(
                                isDragging ? Color.accentColor : Color.secondary.opacity(0.15),
                                style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: isDragging ? [8] : [])
                            )
                    )
                    .shadow(color: Color.black.opacity(0.03), radius: 15, x: 0, y: 4)
                
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.08))
                            .frame(width: 88, height: 88)
                        
                        Circle()
                            .fill(Color.accentColor.opacity(0.05))
                            .frame(width: 76, height: 76)
                        
                        Image(systemName: isDragging ? "arrow.down.circle.fill" : "arrow.up.circle")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundColor(.accentColor)
                            .symbolEffect(.bounce.up.byLayer, value: isDragging)
                    }
                    .scaleEffect(isDragging ? 1.1 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
                    
                    VStack(spacing: 6) {
                        Text(isDragging ? "Release to Convert" : "Drop Files to Convert")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                        
                        Text("or click to browse")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
                .padding(40)
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
            
            HStack(spacing: 8) {
                Image(systemName: getFormatIcon())
                    .foregroundColor(.accentColor.opacity(0.9))
                    .font(.system(size: 13))
                Text("Converting to \(selectedFormat.localizedDescription ?? selectedFormat.identifier)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
    
    private func getFormatIcon() -> String {
        if selectedFormat.conforms(to: .image) {
            return "photo"
        } else if selectedFormat.conforms(to: .audiovisualContent) {
            return "film"
        } else if selectedFormat.conforms(to: .audio) {
            return "music.note"
        }
        return "doc"
    }
}
