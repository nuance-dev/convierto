import SwiftUI
import UniformTypeIdentifiers

struct FormatSelectorMenu: View {
    @Binding var selectedFormat: UTType
    let supportedTypes: [String: [UTType]]
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Search header
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    
                    TextField("Search formats...", text: .constant(""))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(colorScheme == .dark ? 
                            Color.black.opacity(0.3) : 
                            Color.white.opacity(0.8))
                )
                .padding(.horizontal, 16)
                .padding(.top, 16)
                
                // Categories
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(supportedTypes.keys.sorted(), id: \.self) { category in
                            VStack(alignment: .leading, spacing: 12) {
                                // Category Header
                                Text(category)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 16)
                                
                                // Format Grid
                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: 8) {
                                    ForEach(supportedTypes[category] ?? [], id: \.identifier) { format in
                                        FormatButton(
                                            format: format,
                                            isSelected: format == selectedFormat,
                                            action: {
                                                withAnimation(.spring(response: 0.3)) {
                                                    selectedFormat = format
                                                    isPresented = false
                                                }
                                            }
                                        )
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
            .frame(width: 400, height: 500)
            .background(
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                    
                    RoundedRectangle(cornerRadius: 20)
                        .fill(colorScheme == .dark ? 
                            Color.black.opacity(0.3) : 
                            Color.white.opacity(0.5))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .position(
                x: geometry.frame(in: .global).midX,
                y: geometry.frame(in: .global).midY
            )
        }
        .ignoresSafeArea()
        .background(Color.black.opacity(0.2))
        .onTapGesture {
            isPresented = false
        }
    }
}

struct FormatButton: View {
    let format: UTType
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Format Icon
                ZStack {
                    Circle()
                        .fill(isSelected ? 
                            Color.accentColor.opacity(0.15) : 
                            Color.secondary.opacity(0.1))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: getFormatIcon(for: format))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(
                            isSelected ? 
                                Color.accentColor : 
                                Color.primary.opacity(0.8)
                        )
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.localizedDescription ?? format.identifier)
                        .font(.system(size: 13, weight: .medium))
                    
                    Text(getFormatDescription(for: format))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? 
                        (colorScheme == .dark ? 
                            Color.white.opacity(0.05) : 
                            Color.black.opacity(0.05)) : 
                        Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? 
                            Color.accentColor.opacity(0.2) : 
                            Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
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

extension FormatSelectorMenu {
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

extension FormatButton {
    func getFormatDescription(for format: UTType) -> String {
        FormatSelectorMenu.getFormatDescription(for: format)
    }
    
    func getFormatIcon(for format: UTType) -> String {
        FormatSelectorMenu.getFormatIcon(for: format)
    }
} 