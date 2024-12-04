import UniformTypeIdentifiers

extension UTType {
    // Image formats - using optional initialization
    static let webP = UTType("public.webp") ?? .png
    static let raw = UTType("public.camera-raw-image") ?? .jpeg
    
    // Audio formats
    static let aac = UTType("public.aac-audio") ?? .mp3
    static let m4a = UTType("public.mpeg-4-audio") ?? .mp3
    static let aiff = UTType("public.aiff-audio") ?? .wav
    static let midi = UTType("public.midi-audio") ?? .mp3
    
    // Video formats
    static let avi = UTType("public.avi") ?? .mpeg4Movie
    static let m2v = UTType("public.mpeg-2-video") ?? .mpeg4Movie
    
    // Helper properties
    var isAudioFormat: Bool {
        self.conforms(to: .audio)
    }
    
    var isVideoFormat: Bool {
        self.conforms(to: .audiovisualContent)
    }
    
    var isImageFormat: Bool {
        self.conforms(to: .image)
    }
    
    var isPDFFormat: Bool {
        self == .pdf
    }
    
    // Helper for getting file icon
    var systemImageName: String {
        if isImageFormat {
            return "photo"
        } else if isVideoFormat {
            return "film"
        } else if isAudioFormat {
            return "waveform"
        } else if isPDFFormat {
            return "doc"
        } else {
            return "doc.fill"
        }
    }
} 