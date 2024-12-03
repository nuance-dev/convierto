import SwiftUI

struct ProcessingView: View {
    let progress: Double
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 32) {
            // Animated progress circle
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 8)
                    .frame(width: 80, height: 80)
                
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6), value: progress)
                
                // Spinning inner circle
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.accentColor, .accentColor.opacity(0.8)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .rotationEffect(.degrees(isAnimating ? 360 : 0))
                    .animation(
                        .linear(duration: 2)
                        .repeatForever(autoreverses: false),
                        value: isAnimating
                    )
            }
            
            VStack(spacing: 8) {
                Text("Converting")
                    .font(.system(size: 16, weight: .medium))
                
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .animation(.spring(response: 0.3), value: progress)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            isAnimating = true
        }
    }
} 