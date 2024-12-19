import SwiftUI

struct CommandPalette<Content: View>: View {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content
    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.95
    
    var body: some View {
        GeometryReader { geometry in
            if isPresented {
                ZStack {
                    // Backdrop blur and overlay
                    Color.black
                        .opacity(0.2 * opacity)
                        .ignoresSafeArea()
                        .onTapGesture {
                            dismiss()
                        }
                    
                    // Content container
                    VStack(spacing: 0) {
                        content()
                    }
                    .frame(width: min(geometry.size.width - 40, 400))
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.windowBackgroundColor).opacity(0.98))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
                    .padding(.top, geometry.size.height * 0.1)
                    .scaleEffect(scale)
                    .opacity(opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .onAppear {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        opacity = 1
                        scale = 1
                    }
                }
            }
        }
    }
    
    private func dismiss() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            opacity = 0
            scale = 0.95
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isPresented = false
        }
    }
} 