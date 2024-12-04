import AVFoundation
import AppKit
import UniformTypeIdentifiers

class AudioProcessor: BaseConverter, MediaConverting {
    private let visualizer: AudioVisualizer
    private var processingTap: MTAudioProcessingTap?
    
    override init(settings: ConversionSettings = ConversionSettings()) {
        self.visualizer = AudioVisualizer(size: CGSize(width: 1920, height: 1080))
        super.init(settings: settings)
    }
    
    func canConvert(from: UTType, to: UTType) -> Bool {
        if from.conforms(to: .audio) {
            return to.conforms(to: .audio) ||
                   to.conforms(to: .audiovisualContent) ||
                   to.conforms(to: .image)
        }
        return false
    }
    
    func convert(_ url: URL, to format: UTType, progress: Progress) async throws -> ProcessingResult {
        let asset = AVAsset(url: url)
        
        guard try await asset.load(.isPlayable) else {
            throw ConversionError.invalidInput
        }
        
        if format.conforms(to: .audiovisualContent) {
            return try await createVisualization(for: asset, outputFormat: format, progress: progress)
        }
        
        if format.conforms(to: .image) {
            return try await createWaveformImage(for: asset, outputFormat: format, progress: progress)
        }
        
        // Standard audio conversion
        guard let exportSession = try await createExportSession(
            for: asset,
            outputFormat: format,
            isAudioOnly: true
        ) else {
            throw ConversionError.exportFailed
        }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.preferredFilenameExtension ?? "m4a")
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        if let audioMix = try await createEnhancedAudioMix(for: asset) {
            exportSession.audioMix = audioMix
        }
        
        progress.totalUnitCount = 100
        let progressTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
        let progressObserver = progressTimer.sink { [weak exportSession] _ in
            guard let session = exportSession else { return }
            progress.completedUnitCount = Int64(session.progress * 100)
        }
        
        defer {
            progressObserver.cancel()
        }
        
        await exportSession.export()
        
        guard exportSession.status == .completed else {
            throw exportSession.error ?? ConversionError.exportFailed
        }
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: url.lastPathComponent,
            suggestedFileName: url.deletingPathExtension().lastPathComponent + "." + (format.preferredFilenameExtension ?? "m4a"),
            fileType: format
        )
    }
    
    private func createEnhancedAudioMix(for asset: AVAsset) async throws -> AVAudioMix? {
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        
        let audioMix = AVMutableAudioMix()
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: { (tap, clientInfo, tapStorageOut) in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { _ in },
            prepare: { _, _, _ in },
            unprepare: { _ in },
            process: { (tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut) in
                numberFramesOut.pointee = numberFrames
                flagsOut.pointee = MTAudioProcessingTapFlags()
                
                var timeRange = CMTimeRange()
                MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, nil, &timeRange, numberFramesOut)
            }
        )
        
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        
        guard status == noErr, let unwrappedTap = tap?.takeRetainedValue() else {
            return nil
        }
        
        self.processingTap = unwrappedTap
        parameters.audioTapProcessor = unwrappedTap
        parameters.audioTimePitchAlgorithm = .spectral
        
        audioMix.inputParameters = [parameters]
        return audioMix
    }
    
    private func createVisualization(for asset: AVAsset, outputFormat: UTType, progress: Progress) async throws -> ProcessingResult {
        // Implementation for audio visualization
        // This will be implemented in the next iteration
        throw ConversionError.conversionFailed
    }
    
    private func createWaveformImage(for asset: AVAsset, outputFormat: UTType, progress: Progress) async throws -> ProcessingResult {
        let waveformImage = try await visualizer.generateWaveformImage(for: asset)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(outputFormat.preferredFilenameExtension ?? "png")
        
        guard let imageRep = NSBitmapImageRep(data: waveformImage.tiffRepresentation!) else {
            throw ConversionError.conversionFailed
        }
        
        let imageData: Data?
        switch outputFormat {
        case .jpeg:
            imageData = imageRep.representation(using: .jpeg, properties: [:])
        case .png:
            imageData = imageRep.representation(using: .png, properties: [:])
        default:
            imageData = imageRep.representation(using: .png, properties: [:])
        }
        
        guard let data = imageData else {
            throw ConversionError.conversionFailed
        }
        
        try data.write(to: outputURL)
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "waveform.png",
            suggestedFileName: "audio_waveform." + (outputFormat.preferredFilenameExtension ?? "png"),
            fileType: outputFormat
        )
    }
}
