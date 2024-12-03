import Foundation

@MainActor
final class SendableWrapper {
    private let provider: NSItemProvider
    
    init(_ provider: NSItemProvider) {
        self.provider = provider
    }
    
    func loadItem(forTypeIdentifier typeIdentifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier) { (item, error) in
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
    
    var canLoadObject: Bool {
        provider.canLoadObject(ofClass: URL.self)
    }
}