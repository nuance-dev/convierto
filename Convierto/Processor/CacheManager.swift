// CacheManager.swift
import Foundation
import AppKit

class CacheManager {
    static let shared = CacheManager()
    
    private let cacheDirectory: URL
    private let maxCacheAge: TimeInterval = 24 * 60 * 60 // 24 hours
    
    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = cacheDir.appendingPathComponent("com.convierto.filecache", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create cache directory: \(error)")
        }
        
        // Setup automatic cleanup
        setupAutomaticCleanup()
    }
    
    func createTemporaryURL(for filename: String) throws -> URL {
           // Clean the filename
           let cleanFilename = filename.components(separatedBy: "_").last ?? filename
           let tempFilename = "\(UUID().uuidString).\(cleanFilename)"
           let fileURL = cacheDirectory.appendingPathComponent(tempFilename)
           
           // Check if file already exists and remove it
           if FileManager.default.fileExists(atPath: fileURL.path) {
               try FileManager.default.removeItem(at: fileURL)
           }
           
           return fileURL
       }
    
    func cleanupOldFiles() {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: resourceKeys,
            options: .skipsHiddenFiles
        ) else { return }
        
        let cutoffDate = Date().addingTimeInterval(-maxCacheAge)
        
        while let fileURL = enumerator.nextObject() as? URL {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                if let creationDate = resourceValues.creationDate,
                   let isDirectory = resourceValues.isDirectory,
                   !isDirectory && creationDate < cutoffDate {
                    try fileManager.removeItem(at: fileURL)
                }
            } catch {
                print("Error cleaning up file at \(fileURL): \(error)")
            }
        }
    }
    
    private func setupAutomaticCleanup() {
        // Clean up on app launch
        cleanupOldFiles()
        
        // Register for app termination notification
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cleanupOldFiles()
        }
    }
    
    func cleanupTemporaryFiles() throws {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: resourceKeys,
            options: .skipsHiddenFiles
        ) else { return }
        
        let cutoffDate = Date().addingTimeInterval(-maxCacheAge)
        
        while let fileURL = enumerator.nextObject() as? URL {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                if let creationDate = resourceValues.creationDate,
                   let isDirectory = resourceValues.isDirectory,
                   !isDirectory && creationDate < cutoffDate {
                    try fileManager.removeItem(at: fileURL)
                }
            } catch {
                print("Error cleaning up file at \(fileURL): \(error)")
            }
        }
    }
}
