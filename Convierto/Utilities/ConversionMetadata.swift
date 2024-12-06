import Foundation
import UniformTypeIdentifiers

struct ConversionMetadata {
    let originalFileName: String?
    let originalFileType: UTType?
    let creationDate: Date?
    let modificationDate: Date?
    let fileSize: Int64?
    let additionalMetadata: [String: Any]?
    
    init(
        originalFileName: String? = nil,
        originalFileType: UTType? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        fileSize: Int64? = nil,
        additionalMetadata: [String: Any]? = nil
    ) {
        self.originalFileName = originalFileName
        self.originalFileType = originalFileType
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.additionalMetadata = additionalMetadata
    }
}

extension ConversionMetadata {
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let fileName = originalFileName {
            dict["originalFileName"] = fileName
        }
        if let fileType = originalFileType {
            dict["originalFileType"] = fileType
        }
        if let created = creationDate {
            dict["creationDate"] = created
        }
        if let modified = modificationDate {
            dict["modificationDate"] = modified
        }
        dict["fileSize"] = fileSize
        return dict
    }
}