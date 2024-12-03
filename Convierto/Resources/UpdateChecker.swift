import Foundation

struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let body: String
    let htmlUrl: String
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
    }
}

class UpdateChecker: ObservableObject {
    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var releaseNotes: String?
    @Published var downloadURL: URL?
    @Published var isChecking = false
    @Published var error: String?
    @Published var statusIcon: String = "checkmark.circle"
    
    var onStatusChange: ((String) -> Void)?
    var onUpdateAvailable: (() -> Void)?
    
    private let currentVersion: String
    private let githubRepo: String
    private var updateCheckTimer: Timer?
    
    init() {
            self.currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
            self.githubRepo = "nuance-dev/Convierto"
            setupTimer()
            updateStatusIcon()
        }
    
    private func setupTimer() {
        // Initial check after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkForUpdates()
        }
        
        // Periodic check every 24 hours
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }
    
    private func updateStatusIcon() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isChecking {
                self.statusIcon = "arrow.triangle.2.circlepath"
            } else {
                self.statusIcon = self.updateAvailable ? "exclamationmark.circle" : "checkmark.circle"
            }
            self.onStatusChange?(self.statusIcon)
        }
    }
    
    func checkForUpdates() {
        print("Checking for updates...")
        print("Current version: \(currentVersion)")
        
        isChecking = true
        updateStatusIcon()
        error = nil
        
        let baseURL = "https://api.github.com/repos/\(githubRepo)/releases/latest"
        guard let url = URL(string: baseURL) else {
            error = "Invalid GitHub repository URL"
            isChecking = false
            updateStatusIcon()
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Convierto-App/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleUpdateResponse(data: data, response: response as? HTTPURLResponse, error: error)
            }
        }.resume()
    }
    
    private func handleUpdateResponse(data: Data?, response: HTTPURLResponse?, error: Error?) {
        defer {
            isChecking = false
            updateStatusIcon()
        }
        
        if let error = error {
            print("Network error: \(error)")
            self.error = "Network error: \(error.localizedDescription)"
            return
        }
        
        guard let response = response else {
            print("Invalid response")
            self.error = "Invalid response from server"
            return
        }
        
        print("Response status code: \(response.statusCode)")
        
        guard response.statusCode == 200 else {
            self.error = "Server error: \(response.statusCode)"
            return
        }
        
        guard let data = data else {
            self.error = "No data received"
            return
        }
        
        do {
            
            let decoder = JSONDecoder()
            let release = try decoder.decode(GitHubRelease.self, from: data)
            
            let cleanLatestVersion = release.tagName.replacingOccurrences(of: "v", with: "")
            print("Latest version: \(cleanLatestVersion)")
            print("Current version for comparison: \(currentVersion)")
            
            updateAvailable = compareVersions(current: currentVersion, latest: cleanLatestVersion)
                        if updateAvailable {
                            DispatchQueue.main.async {
                                self.onUpdateAvailable?()
                            }
                        }
            
            latestVersion = cleanLatestVersion
            releaseNotes = release.body
            downloadURL = URL(string: release.htmlUrl)
            
            updateAvailable = compareVersions(current: currentVersion, latest: cleanLatestVersion)
            print("Update available: \(updateAvailable)")
            
        } catch {
            print("Parsing error: \(error)")
            self.error = "Failed to parse response: \(error.localizedDescription)"
        }
    }
    
    private func compareVersions(current: String, latest: String) -> Bool {
        // Clean and split versions
        let currentParts = current.replacingOccurrences(of: "v", with: "")
            .split(separator: ".")
            .compactMap { Int($0) }
        
        let latestParts = latest.replacingOccurrences(of: "v", with: "")
            .split(separator: ".")
            .compactMap { Int($0) }
        
        
        // Ensure we have at least 3 components (major.minor.patch)
        let paddedCurrent = currentParts + Array(repeating: 0, count: max(3 - currentParts.count, 0))
        let paddedLatest = latestParts + Array(repeating: 0, count: max(3 - latestParts.count, 0))
        
        
        // Compare each version component
        for i in 0..<min(paddedCurrent.count, paddedLatest.count) {
            if paddedLatest[i] > paddedCurrent[i] {
                return true
            } else if paddedLatest[i] < paddedCurrent[i] {
                return false
            }
        }
        
        print("Versions are equal")
        return false
    }
    
    deinit {
        updateCheckTimer?.invalidate()
    }
}
