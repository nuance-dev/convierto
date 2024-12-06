import Foundation

enum ConversionError: LocalizedError {
    case invalidInput
    case conversionFailed
    case exportFailed
    case incompatibleFormats
    case unsupportedFormat
    case insufficientMemory
    case insufficientDiskSpace
    case timeout
    case documentProcessingFailed
    case documentUnsupported
    case documentConversionFailed
    case fileAccessDenied
    case sandboxViolation
    
    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Invalid input file"
        case .conversionFailed:
            return "Conversion failed"
        case .exportFailed:
            return "Failed to export the converted file"
        case .incompatibleFormats:
            return "Incompatible input and output formats"
        case .unsupportedFormat:
            return "Unsupported file format"
        case .timeout:
            return "Operation timed out"
        case .insufficientMemory:
            return "Insufficient memory available"
        case .insufficientDiskSpace:
            return "Insufficient disk space available"
        case .documentProcessingFailed:
            return "Failed to process the document"
        case .documentUnsupported:
            return "Unsupported document format"
        case .documentConversionFailed:
            return "Failed to convert the document"
        case .fileAccessDenied:
            return "File access denied"
        case .sandboxViolation:
            return "Sandbox violation"
        }
    }
} 