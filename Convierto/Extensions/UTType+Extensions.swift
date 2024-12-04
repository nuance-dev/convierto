import UniformTypeIdentifiers

extension UTType {
    // Audio formats
    static let aac = UTType("public.aac-audio")!
    static let m4a = UTType("public.mpeg-4-audio")!
    static let midi = UTType("public.midi-audio")!
    
    // Video formats
    static let m2v = UTType("public.mpeg-2-video")!
    static let avi = UTType("public.avi")!
    
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
} 