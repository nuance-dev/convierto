import SwiftUI

class ProcessingViewModel: ObservableObject {
    @Published var currentStage: ConversionStage = .idle
    @Published var progress: Double = 0
    @Published var isAnimating = false
    
    private var stageObserver: NSObjectProtocol?
    private var progressObserver: NSObjectProtocol?
    
    func setupNotificationObservers() {
        stageObserver = NotificationCenter.default.addObserver(
            forName: .processingStageChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let stage = notification.userInfo?["stage"] as? ConversionStage else { return }
            
            withAnimation(.easeInOut(duration: 0.3)) {
                self?.currentStage = stage
                self?.updateAnimationState(for: stage)
            }
        }
        
        progressObserver = NotificationCenter.default.addObserver(
            forName: .processingProgressUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let newProgress = notification.userInfo?["progress"] as? Double else { return }
            
            withAnimation(.linear(duration: 0.2)) {
                self?.progress = max(0, min(1, newProgress))
            }
        }
    }
    
    func removeNotificationObservers() {
        if let observer = stageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = progressObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func updateAnimationState(for stage: ConversionStage) {
        isAnimating = stage.shouldAnimate
    }
}

struct ProcessingView: View {
    @StateObject private var viewModel = ProcessingViewModel()
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                    .frame(width: 64, height: 64)
                
                Circle()
                    .trim(from: 0, to: max(0.01, viewModel.progress)) // Ensure minimum visible progress
                    .stroke(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: viewModel.progress)
                
                Image(systemName: getStageIcon())
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(viewModel.isAnimating ? 0.5 : 1.0)
                    .animation(
                        viewModel.isAnimating ? 
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : 
                            .default,
                        value: viewModel.isAnimating
                    )
            }
            
            Text(getStageText())
                .font(.system(size: 16, weight: .medium))
            
            Text("\(Int(viewModel.progress * 100))%")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .contentTransition(.numericText())
            
            Button(action: {
                withAnimation(.spring(response: 0.3)) {
                    onCancel()
                }
            }) {
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
            viewModel.setupNotificationObservers()
            startAnimating()
        }
        .onDisappear {
            viewModel.removeNotificationObservers()
            stopAnimating()
        }
    }
    
    private func startAnimating() {
        viewModel.isAnimating = viewModel.currentStage.shouldAnimate
    }
    
    private func stopAnimating() {
        viewModel.isAnimating = false
    }
    
    private func getStageIcon() -> String {
        switch viewModel.currentStage {
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
        switch viewModel.currentStage {
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

// Add extension to ConversionStage
extension ConversionStage {
    var shouldAnimate: Bool {
        switch self {
        case .idle, .analyzing, .converting, .optimizing, .finalizing:
            return true
        case .completed, .failed:
            return false
        }
    }
} 
