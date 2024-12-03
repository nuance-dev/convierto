import Foundation

@MainActor
struct SendableItemProvider: @unchecked Sendable {
    private let provider: NSItemProvider
    
    init(_ provider: NSItemProvider) {
        self.provider = provider
    }
    
    func loadItem(forTypeIdentifier: String) async throws -> Any? {
        return try await provider.loadItem(forTypeIdentifier: forTypeIdentifier)
    }
    
    var canLoadObject: Bool {
        return provider.canLoadObject(ofClass: URL.self)
    }
} 