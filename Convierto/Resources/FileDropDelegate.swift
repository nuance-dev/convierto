import SwiftUI
import UniformTypeIdentifiers

struct FileDropDelegate: DropDelegate {
    @Binding var isDragging: Bool
    let supportedTypes: [UTType]
    let handleDrop: ([NSItemProvider]) -> Void
    
    func validateDrop(info: DropInfo) -> Bool {
        print("Validating drop...")
        
        // First check for file URL conformance
        guard info.hasItemsConforming(to: [.fileURL]) else {
            print("Drop items don't conform to fileURL")
            return false
        }
        
        let providers = info.itemProviders(for: [.fileURL])
        print("Found \(providers.count) providers")
        
        // Validate each provider
        return providers.allSatisfy { provider in
            let canLoadURL = provider.canLoadObject(ofClass: URL.self)
            print("Provider can load URL: \(canLoadURL)")
            return canLoadURL
        }
    }
    
    func dropEntered(info: DropInfo) {
        print("Drop entered")
        withAnimation(.easeInOut(duration: 0.2)) {
            isDragging = validateDrop(info: info)
        }
    }
    
    func dropExited(info: DropInfo) {
        print("Drop exited")
        withAnimation(.easeInOut(duration: 0.2)) {
            isDragging = false
        }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        print("Performing drop")
        isDragging = false
        let providers = info.itemProviders(for: [.fileURL])
        handleDrop(providers)
        return true
    }
}
