import Foundation
import UniformTypeIdentifiers

enum ConversionError: LocalizedError {
    case invalidInput
    case conversionFailed(reason: String)
    case exportFailed(reason: String)
    case incompatibleFormats(from: UTType, to: UTType, reason: String? = nil)
    case unsupportedFormat(format: UTType)
    case insufficientMemory(required: UInt64, available: UInt64)
    case insufficientDiskSpace(required: UInt64, available: UInt64)
    case timeout(duration: TimeInterval)
    case documentProcessingFailed(reason: String)
    case documentUnsupported(format: UTType)
    case fileAccessDenied(path: String)
    case sandboxViolation(reason: String)
    case contextError(reason: String)
    case resourceExhausted(resource: String)
    case conversionNotPossible(reason: String)
    case invalidInputType
    case cancelled
    case featureNotImplemented(feature: String)
    case invalidConfiguration(String)
    case unsupportedConversion(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid input file"
        case .conversionFailed(let reason):
            return "Conversion failed: \(reason)"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .incompatibleFormats(let from, let to, let reason):
            return "Cannot convert from \(from.localizedDescription ?? "unknown") to \(to.localizedDescription ?? "unknown"). Reason: \(reason ?? "unknown")"
        case .unsupportedFormat(let format):
            return "Unsupported format: \(format.localizedDescription ?? "unknown")"
        case .insufficientMemory(let required, let available):
            return "Insufficient memory: Required \(ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .binary)), Available \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .binary))"
        case .insufficientDiskSpace(let required, let available):
            return "Insufficient disk space: Required \(ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .binary)), Available \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .binary))"
        case .timeout(let duration):
            return "Operation timed out after \(String(format: "%.1f", duration)) seconds"
        case .documentProcessingFailed(let reason):
            return "Document processing failed: \(reason)"
        case .documentUnsupported(let format):
            return "Document format not supported: \(format.localizedDescription ?? "unknown")"
        case .fileAccessDenied(let path):
            return "Access denied to file: \(path)"
        case .sandboxViolation(let reason):
            return "Sandbox violation: \(reason)"
        case .contextError(let reason):
            return "Graphics context error: \(reason)"
        case .resourceExhausted(let resource):
            return "Resource exhausted: \(resource)"
        case .conversionNotPossible(let reason):
            return "Conversion not possible: \(reason)"
        case .invalidInputType:
            return "InvalidInputType"
        case .cancelled:
            return "Operation was cancelled"
        case .featureNotImplemented(let feature):
            return "Feature not implemented: \(feature)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .unsupportedConversion(let reason):
            return "Unsupported conversion: \(reason)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .insufficientMemory:
            return "Try closing other applications or converting smaller files"
        case .insufficientDiskSpace:
            return "Free up disk space and try again"
        case .timeout:
            return "Try converting a smaller file or simplifying the conversion"
        case .conversionNotPossible:
            return "Try converting to a different format or check if the input file is valid"
        default:
            return nil
        }
    }
} 
