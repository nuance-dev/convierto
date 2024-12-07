import SwiftUI

struct ProcessingView: View {
    @StateObject private var tracker = ProgressTracker()
    @State private var progress: Double = 0
    @State private var currentStage: ConversionStage = .idle
    @State private var isAnimating = false
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                    .frame(width: 64, height: 64)
                
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, lineWidth: 4)
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: progress)
                
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
            
            Text(getStageText())
                .font(.system(size: 16, weight: .medium))
            
            Text("\(Int(progress * 100))%")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            
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
            setupNotificationObservers()
        }
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: .processingStageChanged,
            object: nil,
            queue: .main
        ) { notification in
            if let stage = notification.userInfo?["stage"] as? ConversionStage {
                withAnimation {
                    self.currentStage = stage
                }
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .processingProgressUpdated,
            object: nil,
            queue: .main
        ) { notification in
            if let progress = notification.userInfo?["progress"] as? Double {
                withAnimation {
                    self.progress = progress
                }
            }
        }
    }
    
    private func getStageIcon() -> String {
        switch currentStage {
        case .idle: return "gear"
        case .analyzing: return "magnifyingglass"
        case .converting: return "arrow.triangle.2.circlepath"
        case .optimizing: return "slider.horizontal.3"
        case .finalizing: return "checkmark.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle"
        }
    }
    
    private func getStageText() -> String {
        switch currentStage {
        case .idle: return "Preparing..."
        case .analyzing: return "Analyzing..."
        case .converting: return "Converting..."
        case .optimizing: return "Optimizing..."
        case .finalizing: return "Finalizing..."
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
} 
