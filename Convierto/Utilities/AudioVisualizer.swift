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
    
    // Modern color palette inspired by League of Legends
    private let backgroundColors: [CGColor] = [
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 1.0).cgColor, // Deep space blue
        NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.20, alpha: 1.0).cgColor  // Midnight blue
    ]
    
    private let orbColors: [CGColor] = [
        NSColor(calibratedRed: 0.0, green: 0.8, blue: 1.0, alpha: 0.8).cgColor,    // Cosmic blue
        NSColor(calibratedRed: 0.4, green: 0.0, blue: 1.0, alpha: 0.6).cgColor,    // Deep purple
        NSColor(calibratedRed: 1.0, green: 0.4, blue: 0.0, alpha: 0.7).cgColor     // Energy orange
    ]
    
    // Particle system properties
    private struct Particle {
        var position: CGPoint
        var velocity: CGPoint
        var size: CGFloat
        var alpha: CGFloat
        var color: CGColor
        var life: CGFloat
    }
    
    private var particles: [Particle] = []
    private let maxParticles = 150
    
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
            Int(duration.seconds * 30),
            1800
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
            AVSampleRateKey: 44100.0
        ]
        
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(output)
        
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
                samples.reserveCapacity(samples.count + sampleCount)
                
                var data = [Float](repeating: 0, count: sampleCount)
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)
                samples.append(contentsOf: data)
            }
        }
        
        reader.cancelReading()
        return samples
    }
    
    private func generateVisualizationFrame(from samples: [Float]) async throws -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw ConversionError.conversionFailed(reason: "Failed to create graphics context")
        }
        
        // Draw cosmic background
        drawCosmicBackground(in: context)
        
        // Process audio data
        let frequencies = processFrequencyBands(samples)
        
        // Update and draw particle system
        updateParticleSystem(frequencies: frequencies)
        drawParticles(in: context)
        
        // Draw energy orbs
        drawEnergyOrbs(frequencies: frequencies, in: context)
        
        // Add bloom effect
        applyBloomEffect(to: context)
        
        return context.makeImage()
    }
    
    private func drawCosmicBackground(in context: CGContext) {
        // Create a gradient background with subtle noise
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: backgroundColors as CFArray,
            locations: [0.0, 1.0]
        ) else { return }
        
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size.height),
            end: CGPoint(x: size.width, y: 0),
            options: []
        )
        
        // Add subtle noise texture
        addNoiseTexture(to: context)
    }
    
    private func processFrequencyBands(_ samples: [Float]) -> [Float] {
        // Process audio data into frequency bands using FFT
        // Return normalized frequency bands
        // This is a simplified version - implement proper FFT for production
        let bandCount = 8
        var bands = [Float](repeating: 0, count: bandCount)
        let samplesPerBand = samples.count / bandCount
        
        for i in 0..<bandCount {
            let start = i * samplesPerBand
            let end = start + samplesPerBand
            let bandSamples = samples[start..<end]
            bands[i] = bandSamples.map { abs($0) }.max() ?? 0
        }
        
        return bands.map { min($0 * 2, 1.0) } // Normalize
    }
    
    private func updateParticleSystem(frequencies: [Float]) {
        // Update existing particles
        particles = particles.compactMap { particle in
            var updated = particle
            updated.position.x += particle.velocity.x
            updated.position.y += particle.velocity.y
            updated.life -= 0.016 // Assuming 60fps
            updated.alpha = updated.life
            
            return updated.life > 0 ? updated : nil
        }
        
        // Generate new particles based on audio intensity
        let intensity = frequencies.reduce(0, +) / Float(frequencies.count)
        let newParticleCount = Int(intensity * 10)
        
        for _ in 0..<newParticleCount where particles.count < maxParticles {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let speed = CGFloat.random(in: 1...3)
            particles.append(Particle(
                position: CGPoint(x: size.width/2, y: size.height/2),
                velocity: CGPoint(x: cos(angle) * speed, y: sin(angle) * speed),
                size: CGFloat.random(in: 2...6),
                alpha: 1.0,
                color: orbColors.randomElement()!,
                life: 1.0
            ))
        }
    }
    
    private func drawParticles(in context: CGContext) {
        for particle in particles {
            context.setFillColor(particle.color.copy(alpha: particle.alpha)!)
            let rect = CGRect(
                x: particle.position.x - particle.size/2,
                y: particle.position.y - particle.size/2,
                width: particle.size,
                height: particle.size
            )
            context.fillEllipse(in: rect)
        }
    }
    
    private func drawEnergyOrbs(frequencies: [Float], in context: CGContext) {
        let centerX = size.width / 2
        let centerY = size.height / 2
        let maxRadius = min(size.width, size.height) * 0.4
        
        // Draw central orb
        let centralOrbSize = maxRadius * 0.3 * CGFloat(frequencies.reduce(0, +) / Float(frequencies.count))
        drawGlowingOrb(at: CGPoint(x: centerX, y: centerY),
                      radius: centralOrbSize,
                      color: orbColors[0],
                      in: context)
        
        // Draw orbital orbs
        for (index, frequency) in frequencies.enumerated() {
            let angle = (2 * .pi * Double(index)) / Double(frequencies.count)
            let orbitalRadius = maxRadius * CGFloat(0.5 + frequency * 0.5)
            let x = centerX + cos(angle) * orbitalRadius
            let y = centerY + sin(angle) * orbitalRadius
            let orbSize = maxRadius * 0.15 * CGFloat(frequency)
            
            drawGlowingOrb(at: CGPoint(x: x, y: y),
                          radius: orbSize,
                          color: orbColors[index % orbColors.count],
                          in: context)
        }
    }
    
    private func drawGlowingOrb(at center: CGPoint, radius: CGFloat, color: CGColor, in context: CGContext) {
        // Draw core
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                     width: radius * 2, height: radius * 2))
        
        // Draw glow
        for i in 1...3 {
            let alpha = 0.3 / CGFloat(i)
            context.setFillColor(color.copy(alpha: alpha)!)
            let glowRadius = radius * CGFloat(1 + i * Int(0.5))
            context.fillEllipse(in: CGRect(x: center.x - glowRadius, y: center.y - glowRadius,
                                         width: glowRadius * 2, height: glowRadius * 2))
        }
    }
    
    private func addNoiseTexture(to context: CGContext) {
        context.setFillColor(NSColor.white.withAlphaComponent(0.03).cgColor)
        for _ in 0..<1000 {
            let x = CGFloat.random(in: 0..<size.width)
            let y = CGFloat.random(in: 0..<size.height)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    
    private func applyBloomEffect(to context: CGContext) {
        // Implement bloom effect using CIFilter
        guard let image = context.makeImage() else { return }
        let ciImage = CIImage(cgImage: image)
        
        let bloomFilter = CIFilter(name: "CIBloom")
        bloomFilter?.setValue(ciImage, forKey: kCIInputImageKey)
        bloomFilter?.setValue(2.5, forKey: kCIInputRadiusKey)
        bloomFilter?.setValue(1.0, forKey: kCIInputIntensityKey)
        
        if let outputImage = bloomFilter?.outputImage,
           let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) {
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
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
        
        logger.debug("Initializing video writer")
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        
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
        
        let audioInput: AVAssetWriterInput?
        if let audioAsset = audioAsset,
           let _ = try? await audioAsset.loadTracks(withMediaType: .audio).first {
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
        
        let durationInSeconds = duration.seconds
        let frameDuration = CMTime(seconds: durationInSeconds / Double(frames.count), preferredTimescale: 600)
        
        for (index, frame) in frames.enumerated() {
            let pixelBuffer = try await createPixelBuffer(from: frame)
            
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            
            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
            
            progressHandler?(Double(index) / Double(frames.count) * 0.8)
        }
        
        videoInput.markAsFinished()
        
        if let audioInput = audioInput, let audioAsset = audioAsset {
            try await appendAudioSamples(from: audioAsset, to: audioInput)
            progressHandler?(0.9)
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
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
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
        logger.debug("Generating visualization frames from raw samples")
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
