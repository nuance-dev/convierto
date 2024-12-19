import SwiftUI
import UniformTypeIdentifiers

struct FormatSelectorMenu: View {
    @Binding var selectedFormat: UTType
    let supportedTypes: [String: [UTType]]
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) var colorScheme
    @State private var searchText: String = ""
    @FocusState private var isSearchFocused: Bool
    
    private var filteredTypes: [String: [UTType]] {
        if searchText.isEmpty { return supportedTypes }
        
        return supportedTypes.mapValues { formats in
            formats.filter { format in
                let description = Self.getFormatDescription(for: format).lowercased()
                let identifier = format.identifier.lowercased()
                let fileExtension = format.preferredFilenameExtension?.lowercased() ?? ""
                let searchQuery = searchText.lowercased()
                
                return description.contains(searchQuery) ||
                       identifier.contains(searchQuery) ||
                       fileExtension.contains(searchQuery)
            }
        }.filter { !$0.value.isEmpty }
    }
    
    var body: some View {
        CommandPalette(isPresented: $isPresented) {
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    
                    TextField("Search formats...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isSearchFocused)
                    
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                
                Divider()
                
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(Array(filteredTypes.keys.sorted()), id: \.self) { category in
                            if let formats = filteredTypes[category], !formats.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(category)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 16)
                                    
                                    ForEach(formats, id: \.identifier) { format in
                                        FormatButton(
                                            format: format,
                                            isSelected: format == selectedFormat
                                        ) {
                                            withAnimation(.spring(response: 0.3)) {
                                                selectedFormat = format
                                                isPresented = false
                                            }
                                        }
                                        .padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
        }
        .onAppear {
            isSearchFocused = true
        }
    }
    
    static func getFormatDescription(for format: UTType) -> String {
        switch format {
        case .jpeg:
            return "Compressed image format"
        case .png:
            return "Lossless image format"
        case .heic:
            return "High-efficiency format"
        case .gif:
            return "Animated image format"
        case .pdf:
            return "Document format"
        case .mp3:
            return "Compressed audio"
        case .wav:
            return "Lossless audio"
        case .mpeg4Movie:
            return "High-quality video"
        case .webP:
            return "Web-optimized format"
        case .aiff:
            return "High-quality audio"
        case .m4a:
            return "AAC audio format"
        case .avi:
            return "Video format"
        case .raw:
            return "Camera RAW format"
        case .tiff:
            return "Professional image format"
        default:
            return format.preferredFilenameExtension?.uppercased() ?? 
                   format.identifier.components(separatedBy: ".").last?.uppercased() ?? 
                   "Unknown format"
        }
    }
    
    static func getFormatIcon(for format: UTType) -> String {
        if format.isImageFormat {
            switch format {
            case .heic:
                return "photo.fill"
            case .raw:
                return "camera.aperture"
            case .gif:
                return "square.stack.3d.down.right.fill"
            default:
                return "photo"
            }
        } else if format.isVideoFormat {
            return "film.fill"
        } else if format.isAudioFormat {
            switch format {
            case .mp3:
                return "waveform"
            case .wav:
                return "waveform.circle.fill"
            case .aiff:
                return "waveform.badge.plus"
            default:
                return "music.note"
            }
        } else if format.isPDFFormat {
            return "doc.fill"
        } else {
            return "doc.circle.fill"
        }
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }
    
    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
    }
} 