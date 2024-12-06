import Foundation
import os.log

extension Logger {
    static func makeLogger(category: String) -> Logger {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: category)
    }
} 