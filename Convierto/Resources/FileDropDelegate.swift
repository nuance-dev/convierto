import SwiftUI
import UniformTypeIdentifiers
struct FileDropDelegate: DropDelegate {
    @Binding var isDragging: Bool
    let supportedTypes: [UTType]
    let handleDrop: ([NSItemProvider]) -> Void
    
    func validateDrop(info: DropInfo) -> Bool {
        return info.hasItemsConforming(to: supportedTypes.map(\.identifier))
    }
    
    func dropEntered(info: DropInfo) {
        isDragging = true
    }
    
    func dropExited(info: DropInfo) {
        isDragging = false
    }
    
    func performDrop(info: DropInfo) -> Bool {
        isDragging = false
        let providers = info.itemProviders(for: supportedTypes.map(\.identifier))
        handleDrop(providers)
        return true
    }
}
