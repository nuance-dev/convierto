import SwiftUI

struct ErrorView: View {
    let error: Error
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.red)
            
            Text("Conversion Failed")
                .font(.system(size: 16, weight: .medium))
            
            Text(error.localizedDescription)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: onDismiss) {
                Text("Try Again")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .padding()
    }
}