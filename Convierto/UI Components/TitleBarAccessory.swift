import SwiftUI

struct TitleBarAccessory: View {
    @AppStorage("isDarkMode") private var isDarkMode = false
    
    var body: some View {
        Button(action: {
            isDarkMode.toggle()
        }) {
            Image(systemName: isDarkMode ? "sun.max.fill" : "moon.fill")
                .foregroundColor(.primary)
        }
        .buttonStyle(PlainButtonStyle())
        .frame(width: 30, height: 30)
    }
}
