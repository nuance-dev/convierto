import SwiftUI
import UniformTypeIdentifiers
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
    category: "FileDropDelegate"
)

struct FileDropDelegate: DropDelegate {
    @Binding var isDragging: Bool
    let supportedTypes: [UTType]
    let handleDrop: @MainActor ([NSItemProvider]) -> Void
    
    func validateDrop(info: DropInfo) -> Bool {
        logger.debug("Validating drop...")
        return info.hasItemsConforming(to: [.fileURL])
    }
    
    func performDrop(info: DropInfo) -> Bool {
        logger.debug("Performing drop")
        isDragging = false
        let providers = info.itemProviders(for: [.fileURL])
        
        Task { @MainActor in
            handleDrop(providers)
        }
        
        return true
    }
    
    func dropEntered(info: DropInfo) {
        logger.debug("Drop entered")
        withAnimation(.easeInOut(duration: 0.2)) {
            isDragging = validateDrop(info: info)
        }
    }
    
    func dropExited(info: DropInfo) {
        logger.debug("Drop exited")
        withAnimation(.easeInOut(duration: 0.2)) {
            isDragging = false
        }
    }
}

@MainActor
extension NSItemProvider {
    func loadURL() async throws -> URL? {
        logger.debug("Loading URL from item provider")
        return try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, error in
                if let error = error {
                    logger.error("Failed to load URL: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                } else if let urlData = data as? Data,
                          let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                    logger.debug("Successfully loaded URL: \(url.path)")
                    continuation.resume(returning: url)
                } else if let url = data as? URL {
                    logger.debug("Successfully loaded direct URL: \(url.path)")
                    continuation.resume(returning: url)
                } else {
                    logger.error("Item is not a URL")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

@MainActor
class FileDropHandler {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
        category: "FileDropHandler"
    )
    
    func handleProviders(_ providers: [NSItemProvider], outputFormat: UTType) async throws -> [URL] {
        var urls: [URL] = []
        
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { 
                throw ConversionError.invalidInput
            }
            
            if let url = try await provider.loadURL() {
                logger.debug("Processing URL: \(url.path)")
                
                // Create security-scoped bookmark
                let bookmarkData = try url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                
                var isStale = false
                guard let resolvedURL = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) else {
                    logger.error("Failed to resolve bookmark for URL: \(url.path)")
                    throw ConversionError.fileAccessDenied(path: url.path)
                }
                
                guard resolvedURL.startAccessingSecurityScopedResource() else {
                    logger.error("Failed to access security-scoped resource: \(resolvedURL.path)")
                    throw ConversionError.sandboxViolation(reason: "Cannot access security-scoped resource")
                }
                
                defer {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
                
                // Verify file exists and is readable
                guard FileManager.default.isReadableFile(atPath: resolvedURL.path) else {
                    logger.error("File is not readable: \(resolvedURL.path)")
                    throw ConversionError.fileAccessDenied(path: resolvedURL.path)
                }
                
                urls.append(resolvedURL)
            }
        }
        
        guard !urls.isEmpty else {
            throw ConversionError.invalidInput
        }
        
        return urls
    }
}
