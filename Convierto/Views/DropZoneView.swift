import SwiftUI

struct DropZoneView: View {
    @Binding var isDragging: Bool
    @Binding var shouldResize: Bool
    @Binding var maxDimension: String
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottom) {
                // Main drop zone content - centered
                VStack(spacing: 12) {
                    Image(systemName: "doc.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    
                    Text("Drop your file here")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Resize controls - bottom aligned
                HStack(spacing: 12) {
                    Toggle("Resize", isOn: $shouldResize)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    
                    Text("Resize")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    
                    if shouldResize {
                        TextField("px", text: $maxDimension)
                            .frame(width: 60)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .font(.system(size: 13))
                            .multilineTextAlignment(.trailing)
                        
                        Text("px")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                )
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isDragging ? Color.accentColor : Color.secondary.opacity(0.2),
                                style: StrokeStyle(lineWidth: 1))
                    .background(Color.clear)
            )
            .padding()
        }
        .buttonStyle(PlainButtonStyle())
    }
}
