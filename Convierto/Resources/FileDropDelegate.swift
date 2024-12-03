import SwiftUI
import UniformTypeIdentifiers

struct FileDropDelegate: DropDelegate {
    @Binding var isDragging: Bool
    let supportedTypes: [UTType]
    let handleDrop: ([NSItemProvider]) -> Void
    
    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.fileURL]) else {
            return false
        }
        
        return info.itemProviders(for: [.fileURL]).allSatisfy { provider in
            provider.canLoadObject(ofClass: URL.self)
        }
    }
    
    func dropEntered(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.2)) {
            isDragging = validateDrop(info: info)
        }
    }
    
    func dropExited(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.2)) {
            isDragging = false
        }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        isDragging = false
        let providers = info.itemProviders(for: [.fileURL])
        handleDrop(providers)
        return true
    }
}

// Add a helper extension to handle file loading
extension NSItemProvider {
    func loadURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            self.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

@MainActor
class FileDropHandler {
    func handleProviders(_ providers: [NSItemProvider], outputFormat: UTType) async throws -> [URL] {
        var urls: [URL] = []
        
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            
            if let url = try await provider.loadURL() {
                // Verify file exists and is readable
                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    throw ConversionError.fileAccessDenied
                }
                
                // Start accessing security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    throw ConversionError.sandboxViolation
                }
                
                defer {
                    url.stopAccessingSecurityScopedResource()
                }
                
                // Validate file type
                let resourceValues = try await url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                guard let inputType = resourceValues.contentType else {
                    throw ConversionError.invalidInput
                }
                
                // Check file size (100MB limit)
                if let fileSize = resourceValues.fileSize, fileSize > 100_000_000 {
                    throw ConversionError.fileTooLarge
                }
                
                urls.append(url)
            }
        }
        
        guard !urls.isEmpty else {
            throw ConversionError.invalidInput
        }
        
        return urls
    }
}
