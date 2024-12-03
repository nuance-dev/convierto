import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let nsView = NSView()
        
        DispatchQueue.main.async {
            if let window = nsView.window {
                let titleBarAccessory = NSTitlebarAccessoryViewController()
                let hostingView = NSHostingView(rootView: TitleBarAccessory())
                
                hostingView.frame.size = hostingView.fittingSize
                titleBarAccessory.view = hostingView
                titleBarAccessory.layoutAttribute = .trailing
                
                window.addTitlebarAccessoryViewController(titleBarAccessory)
            }
        }
        
        return nsView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
