import Foundation
import UniformTypeIdentifiers

@MainActor
class SendableItemProviderWrapper {
    private let provider: NSItemProvider
    
    init(_ provider: NSItemProvider) {
        self.provider = provider
    }
    
    var canLoadObject: Bool {
        provider.canLoadObject(ofClass: URL.self)
    }
    
    func loadItem(forTypeIdentifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
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