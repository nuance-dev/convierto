import SwiftUI

struct ProcessingView: View {
    @StateObject private var tracker = ProgressTracker()
    @State private var isAnimating = false
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                    .frame(width: 64, height: 64)
                
                if tracker.isIndeterminate {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(Color.accentColor, lineWidth: 4)
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(isAnimating ? 360 : 0))
                } else {
                    Circle()
                        .trim(from: 0, to: tracker.progress)
                        .stroke(Color.accentColor, lineWidth: 4)
                        .frame(width: 64, height: 64)
                }
                
                Image(systemName: getStageIcon())
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
    
    private func getStageIcon() -> String {
        switch tracker.currentStage {
        case .preparing: return "gear"
        case .loading: return "arrow.down.circle"
        case .analyzing: return "magnifyingglass"
        case .processing: return "arrow.triangle.2.circlepath"
        case .optimizing: return "slider.horizontal.3"
        case .exporting: return "square.and.arrow.up"
        case .finishing: return "checkmark.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle"
        }
    }
    
    private func getStageText() -> String {
        switch tracker.currentStage {
        case .preparing: return "Preparing"
        case .loading: return "Loading"
        case .analyzing: return "Analyzing"
        case .processing: return "Converting"
        case .optimizing: return "Optimizing"
        case .exporting: return "Exporting"
        case .finishing: return "Finishing Up"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
} 
