import AVFoundation
import CoreGraphics
import AppKit
import os.log

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Convierto",
    category: "AudioVisualizer"
)

class AudioVisualizer {
    let size: CGSize
    private let settings = ConversionSettings()
    private let ciContext = CIContext()
    private let colorPalette: [CGColor] = [
        NSColor(calibratedRed: 0.4, green: 0.8, blue: 1.0, alpha: 0.8).cgColor,
        NSColor(calibratedRed: 0.3, green: 0.7, blue: 0.9, alpha: 0.8).cgColor,
        NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.8, alpha: 0.8).cgColor
    ]
    
    init(size: CGSize) {
        self.size = size
    }
    
    func generateVisualizationFrames(
        for asset: AVAsset,
        frameCount: Int? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> [CGImage] {
        logger.debug("Generating visualization frames")
        
        let duration = try await asset.load(.duration)
        let actualFrameCount = frameCount ?? min(
            Int(duration.seconds * 30), // 30 fps
            1800 // Max 60 seconds
        )
        
        var frames: [CGImage] = []
        frames.reserveCapacity(actualFrameCount)
        
        let timeStep = duration.seconds / Double(actualFrameCount)
        
        for frameIndex in 0..<actualFrameCount {
            if Task.isCancelled { break }
            
            let progress = Double(frameIndex) / Double(actualFrameCount)
            progressHandler?(progress)
            
            let time = CMTime(seconds: Double(frameIndex) * timeStep, preferredTimescale: 600)
            
            let samples = try await extractAudioSamples(from: asset, at: time, windowSize: timeStep)
            if let frame = try await generateVisualizationFrame(from: samples) {
                frames.append(frame)
            }
            
            logger.debug("Generated frame \(frameIndex)/\(actualFrameCount)")
            
            // Allow time for memory cleanup
            await Task.yield()
        }
        
        if frames.isEmpty {
            throw ConversionError.conversionFailed(reason: "No frames were generated")
        }
        
        progressHandler?(1.0)
        return frames
    }
    
    private func extractAudioSamples(from asset: AVAsset, at time: CMTime, windowSize: Double) async throws -> [Float] {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.invalidInput
        }
        
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44100.0
        ]
        
        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: outputSettings
        )
        
        reader.add(output)
        
        // Configure time range for reading
        let timeRange = CMTimeRange(
            start: time,
            duration: CMTime(seconds: windowSize, preferredTimescale: 44100)
        )
        reader.timeRange = timeRange
        
        guard reader.startReading() else {
            throw ConversionError.conversionFailed(reason: "Failed to start reading audio")
        }
        
        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            autoreleasepool {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                let sampleCount = length / MemoryLayout<Float>.size
                
                samples.reserveCapacity(sampleCount)
                var data = [Float](repeating: 0, count: sampleCount)
                
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: &data
                )
                
                samples.append(contentsOf: data)
            }
        }
        
        reader.cancelReading()
        return samples
    }
    
    private func generateVisualizationFrame(from samples: [Float]) async throws -> CGImage? {
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )!
        
        // Draw gradient background
        drawBackground(in: context)
        
        // Draw waveform
        drawWaveform(samples: samples, in: context)
        
        // Add particles effect
        drawParticles(samples: samples, in: context)
        
        return context.makeImage()
    }
    
    private func drawBackground(in context: CGContext) {
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.2, alpha: 1.0).cgColor,
                NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.3, alpha: 1.0).cgColor
            ] as CFArray,
            locations: [0, 1]
        )!
        
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: size.height),
            options: []
        )
    }
    
    private func drawWaveform(samples: [Float], in context: CGContext) {
        let path = CGMutablePath()
        let midY = size.height / 2
        let amplitudeScale = size.height / 4
        let xScale = size.width / CGFloat(samples.count)
        
        // Create smooth waveform
        var points: [CGPoint] = []
        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * xScale
            let y = midY + (CGFloat(sample) * amplitudeScale)
            points.append(CGPoint(x: x, y: y))
        }
        
        // Apply Catmull-Rom spline interpolation
        if points.count >= 4 {
            path.move(to: points[0])
            for i in 1..<points.count - 2 {
                let p0 = points[i - 1]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = points[i + 2]
                
                let cp1x = p1.x + (p2.x - p0.x) / 6
                let cp1y = p1.y + (p2.y - p0.y) / 6
                let cp2x = p2.x - (p3.x - p1.x) / 6
                let cp2y = p2.y - (p3.y - p1.y) / 6
                
                path.addCurve(to: p2, control1: CGPoint(x: cp1x, y: cp1y), control2: CGPoint(x: cp2x, y: cp2y))
            }
        }
        
        // Draw waveform with glow effect
        context.setShadow(offset: .zero, blur: 10, color: colorPalette[0])
        context.setStrokeColor(colorPalette[0])
        context.setLineWidth(2.0)
        context.addPath(path)
        context.strokePath()
    }
    
    private func drawParticles(samples: [Float], in context: CGContext) {
        let particleCount = 50
        let maxAmplitude = samples.map(abs).max() ?? 1.0
        
        for i in 0..<particleCount {
            let progress = CGFloat(i) / CGFloat(particleCount)
            let x = size.width * progress
            let amplitude = CGFloat(samples[Int(progress * CGFloat(samples.count))] / maxAmplitude)
            let y = size.height/2 + amplitude * size.height/3
            
            let particlePath = CGPath(
                ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4),
                transform: nil
            )
            
            context.addPath(particlePath)
            context.setFillColor(colorPalette[i % colorPalette.count])
            context.fillPath()
        }
    }
    
    func createVideoTrack(
        from frames: [CGImage],
        duration: CMTime,
        settings: ConversionSettings,
        outputURL: URL,
        audioAsset: AVAsset? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> ProcessingResult {
        guard let firstFrame = frames.first else {
            throw ConversionError.conversionFailed(reason: "No frames available")
        }
        
        logger.debug("⚙️ Initializing video writer")
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        
        // Video settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: firstFrame.width,
            AVVideoHeightKey: firstFrame.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 1,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        
        // Add audio input if audio asset is available
        let audioInput: AVAssetWriterInput?
        if let audioAsset = audioAsset,
           let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioBitRate
            ]
            
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = false
            writer.add(audioInput!)
        } else {
            audioInput = nil
        }
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: firstFrame.width,
                kCVPixelBufferHeightKey as String: firstFrame.height
            ]
        )
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // Write video frames
        let durationInSeconds = duration.seconds
        let frameDuration = CMTime(seconds: durationInSeconds / Double(frames.count), preferredTimescale: 600)
        
        for (index, frame) in frames.enumerated() {
            do {
                let pixelBuffer = try await createPixelBuffer(from: frame)
                
                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
                
                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(index))
                adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                
                progressHandler?(Double(index) / Double(frames.count) * 0.8) // 80% for video
            } catch {
                throw ConversionError.conversionFailed(reason: "Failed to process frame \(index): \(error.localizedDescription)")
            }
        }
        
        videoInput.markAsFinished()
        
        // Write audio if available
        if let audioInput = audioInput, let audioAsset = audioAsset {
            try await appendAudioSamples(from: audioAsset, to: audioInput)
            progressHandler?(0.9) // 90% after audio
        }
        
        await writer.finishWriting()
        progressHandler?(1.0)
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: "audio_visualization",
            suggestedFileName: "visualized_audio.mp4",
            fileType: .mpeg4Movie,
            metadata: nil
        )
    }
    
    func generateWaveformImage(for asset: AVAsset, size: CGSize) async throws -> CGImage {
        let samples = try await extractAudioSamples(
            from: asset,
            at: .zero,
            windowSize: try await asset.load(.duration).seconds
        )
        
        guard let frame = try await generateVisualizationFrame(from: samples) else {
            throw ConversionError.conversionFailed(reason: "Failed to generate visualization frame")
        }
        
        return frame
    }
    
    internal func createPixelBuffer(from image: CGImage) async throws -> CVPixelBuffer {
        let width = image.width
        let height = image.height
        
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw ConversionError.conversionFailed(reason: "Failed to create pixel buffer")
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw ConversionError.conversionFailed(reason: "Failed to create context")
        }
        
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)
        
        return buffer
    }
    
    func generateVisualizationFrames(
        from samples: [Float],
        duration: Double,
        frameCount: Int
    ) async throws -> [CGImage] {
        logger.debug("Generating visualization frames")
        var frames: [CGImage] = []
        let samplesPerFrame = samples.count / frameCount
        
        for frameIndex in 0..<frameCount {
            let startIndex = frameIndex * samplesPerFrame
            let endIndex = min(startIndex + samplesPerFrame, samples.count)
            let frameSamples = Array(samples[startIndex..<endIndex])
            
            if let frame = try await generateVisualizationFrame(from: frameSamples) {
                frames.append(frame)
            }
            
            if frameIndex % 10 == 0 {
                logger.debug("Generated frame \(frameIndex)/\(frameCount)")
            }
        }
        
        if frames.isEmpty {
            throw ConversionError.conversionFailed(reason: "No frames generated")
        }
        
        return frames
    }
    
    private func createVisualizationFrame(from samples: [Float], at time: Double) async throws -> CGImage {
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        
        guard let context else {
            throw ConversionError.conversionFailed(reason: "Failed to create graphics context")
        }
        
        // Clear background
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        
        // Use dynamic batch size based on available memory
        let batchSize = min(samples.count, 1024)
        let samplesPerBatch = samples.count / batchSize
        
        for batchIndex in 0..<batchSize {
            autoreleasepool {
                let startIndex = batchIndex * samplesPerBatch
                let endIndex = min(startIndex + samplesPerBatch, samples.count)
                let batchSamples = Array(samples[startIndex..<endIndex])
                
                drawWaveformBatch(
                    context: context,
                    samples: batchSamples,
                    startX: CGFloat(batchIndex) * size.width / CGFloat(batchSize)
                )
            }
        }
        
        guard let image = context.makeImage() else {
            throw ConversionError.conversionFailed(reason: "Failed to create visualization frame")
        }
        
        return image
    }
    
    private func drawWaveformBatch(
        context: CGContext,
        samples: [Float],
        startX: CGFloat
    ) {
        let width = size.width / CGFloat(samples.count)
        let midY = size.height / 2
        
        context.setLineWidth(2.0)
        context.setStrokeColor(colorPalette[0])
        
        for (index, sample) in samples.enumerated() {
            let x = startX + CGFloat(index) * width
            let amplitude = CGFloat(abs(sample))
            let height = amplitude * size.height * 0.8
            
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x, y: midY - height/2))
            path.addLine(to: CGPoint(x: x, y: midY + height/2))
            
            context.addPath(path)
            context.strokePath()
        }
    }
    
    private func appendAudioSamples(from asset: AVAsset, to audioInput: AVAssetWriterInput) async throws {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.conversionFailed(reason: "No audio track found")
        }
        
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2
            ]
        )
        
        reader.add(output)
        
        guard reader.startReading() else {
            throw ConversionError.conversionFailed(reason: "Failed to start reading audio")
        }
        
        while let buffer = output.copyNextSampleBuffer() {
            if audioInput.isReadyForMoreMediaData {
                audioInput.append(buffer)
            } else {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }
        
        audioInput.markAsFinished()
        reader.cancelReading()
    }
}
