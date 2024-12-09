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
    
    // Modern, minimal color palette
    private let backgroundColors: [CGColor] = [
        NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.05, alpha: 1.0).cgColor, // Near black
        NSColor(calibratedRed: 0.06, green: 0.06, blue: 0.09, alpha: 1.0).cgColor  // Deep space
    ]
    
    private let accentColors: [CGColor] = [
        NSColor.white.withAlphaComponent(0.8).cgColor,
        NSColor(calibratedRed: 0.95, green: 0.95, blue: 1.0, alpha: 0.7).cgColor,
        NSColor(calibratedRed: 0.85, green: 0.85, blue: 1.0, alpha: 0.6).cgColor
    ]
    
    // Enhanced particle system
    private struct Particle {
        var position: CGPoint
        var velocity: CGPoint
        var acceleration: CGPoint
        var size: CGFloat
        var alpha: CGFloat
        var color: CGColor
        var life: CGFloat
        var initialLife: CGFloat
        var rotationAngle: CGFloat
        var rotationSpeed: CGFloat
    }
    
    private struct EnergyWave {
        var centerPoint: CGPoint
        var radius: CGFloat
        var targetRadius: CGFloat
        var alpha: CGFloat
        var thickness: CGFloat
        var speed: CGFloat
    }
    
    private var particles: [Particle] = []
    private var energyWaves: [EnergyWave] = []
    private var coreEnergy: CGFloat = 0.0
    private var lastAudioIntensity: CGFloat = 0.0
    private let maxParticles = 500
    
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
        
        // Draw ethereal background
        drawModernBackground(in: context)
        
        // Process audio data
        let frequencies = processFrequencyBands(samples)
        let currentIntensity = CGFloat(frequencies.reduce(0, +) / Float(frequencies.count))
        
        // Smooth intensity transitions
        lastAudioIntensity = lastAudioIntensity * 0.7 + currentIntensity * 0.3
        
        // Update visualization elements
        updateParticleSystem(intensity: lastAudioIntensity)
        updateEnergyWaves(intensity: lastAudioIntensity)
        updateCoreEnergy(intensity: lastAudioIntensity)
        
        // Render visualization elements
        drawEnergyWaves(in: context)
        drawCoreElement(in: context)
        drawParticles(in: context)
        
        // Apply post-processing effects
        applyModernPostProcessing(to: context)
        
        return context.makeImage()
    }
    
    private func drawModernBackground(in context: CGContext) {
        // Create smooth gradient background
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: backgroundColors as CFArray,
            locations: [0.0, 1.0]
        )!
        
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: size.width * 0.5, y: 0),
            end: CGPoint(x: size.width * 0.5, y: size.height),
            options: []
        )
        
        // Add subtle noise texture
        context.setAlpha(0.015)
        for _ in 0..<2000 {
            let x = CGFloat.random(in: 0..<size.width)
            let y = CGFloat.random(in: 0..<size.height)
            let size = CGFloat.random(in: 1...2)
            context.fill(CGRect(x: x, y: y, width: size, height: size))
        }
    }
    
    private func updateParticleSystem(intensity: CGFloat) {
        // Update existing particles
        particles = particles.compactMap { particle in
            var updated = particle
            
            // Apply physics
            updated.velocity.x += updated.acceleration.x
            updated.velocity.y += updated.acceleration.y
            updated.position.x += updated.velocity.x
            updated.position.y += updated.velocity.y
            
            // Update life and appearance
            updated.life -= 0.016
            updated.alpha = pow(updated.life / updated.initialLife, 1.5)
            updated.rotationAngle += updated.rotationSpeed
            
            // Add some turbulence
            updated.acceleration = CGPoint(
                x: updated.acceleration.x + CGFloat.random(in: -0.1...0.1),
                y: updated.acceleration.y + CGFloat.random(in: -0.1...0.1)
            )
            
            return updated.life > 0 ? updated : nil
        }
        
        // Generate new particles based on intensity
        let newParticleCount = Int(intensity * 20)
        
        for _ in 0..<newParticleCount where particles.count < maxParticles {
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let distance = CGFloat.random(in: 50...150)
            let speed = CGFloat.random(in: 2...5)
            
            let particle = Particle(
                position: CGPoint(x: size.width/2, y: size.height/2),
                velocity: CGPoint(
                    x: cos(angle) * speed,
                    y: sin(angle) * speed
                ),
                acceleration: CGPoint(
                    x: cos(angle) * 0.1,
                    y: sin(angle) * 0.1
                ),
                size: CGFloat.random(in: 1...3),
                alpha: 1.0,
                color: accentColors.randomElement()!,
                life: CGFloat.random(in: 0.8...1.2),
                initialLife: 1.0,
                rotationAngle: CGFloat.random(in: 0...(2 * .pi)),
                rotationSpeed: CGFloat.random(in: -0.1...0.1)
            )
            
            particles.append(particle)
        }
    }
    
    private func updateEnergyWaves(intensity: CGFloat) {
        // Update existing waves
        energyWaves = energyWaves.filter { wave in
            wave.alpha > 0.05
        }
        
        // Generate new waves based on intensity
        if intensity > 0.5 && energyWaves.count < 5 {
            let wave = EnergyWave(
                centerPoint: CGPoint(x: size.width/2, y: size.height/2),
                radius: 0,
                targetRadius: min(size.width, size.height) * 0.8,
                alpha: 0.8,
                thickness: CGFloat.random(in: 1...3),
                speed: CGFloat.random(in: 2...4)
            )
            energyWaves.append(wave)
        }
        
        // Update wave properties
        for i in 0..<energyWaves.count {
            energyWaves[i].radius += energyWaves[i].speed
            energyWaves[i].alpha *= 0.95
        }
    }
    
    private func updateCoreEnergy(intensity: CGFloat) {
        // Smooth core energy transitions
        coreEnergy = coreEnergy * 0.8 + intensity * 0.2
    }
    
    private func drawParticles(in context: CGContext) {
        for particle in particles {
            context.saveGState()
            context.setAlpha(particle.alpha)
            context.setFillColor(particle.color)
            
            context.translateBy(x: particle.position.x, y: particle.position.y)
            context.rotate(by: particle.rotationAngle)
            
            let rect = CGRect(
                x: -particle.size/2,
                y: -particle.size/2,
                width: particle.size,
                height: particle.size
            )
            
            context.fillEllipse(in: rect)
            context.restoreGState()
        }
    }
    
    private func drawEnergyWaves(in context: CGContext) {
        for wave in energyWaves {
            context.setStrokeColor(NSColor.white.withAlphaComponent(wave.alpha).cgColor)
            context.setLineWidth(wave.thickness)
            context.strokeEllipse(in: CGRect(
                x: wave.centerPoint.x - wave.radius,
                y: wave.centerPoint.y - wave.radius,
                width: wave.radius * 2,
                height: wave.radius * 2
            ))
        }
    }
    
    private func drawCoreElement(in context: CGContext) {
        let centerX = size.width / 2
        let centerY = size.height / 2
        let baseRadius = min(size.width, size.height) * 0.15
        let currentRadius = baseRadius * (0.8 + coreEnergy * 0.4)
        
        // Draw core glow
        for i in (1...5).reversed() {
            let alpha = (0.2 / CGFloat(i)) * coreEnergy
            context.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            let glowRadius = currentRadius * CGFloat(i)
            context.fillEllipse(in: CGRect(
                x: centerX - glowRadius,
                y: centerY - glowRadius,
                width: glowRadius * 2,
                height: glowRadius * 2
            ))
        }
        
        // Draw core
        context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.fillEllipse(in: CGRect(
            x: centerX - currentRadius,
            y: centerY - currentRadius,
            width: currentRadius * 2,
            height: currentRadius * 2
        ))
    }
    
    private func applyModernPostProcessing(to context: CGContext) {
        guard let image = context.makeImage() else { return }
        let ciImage = CIImage(cgImage: image)
        
        // Apply sophisticated bloom effect
        let bloomFilter = CIFilter(name: "CIBloom")!
        bloomFilter.setValue(ciImage, forKey: kCIInputImageKey)
        bloomFilter.setValue(3.0, forKey: kCIInputRadiusKey)
        bloomFilter.setValue(1.0, forKey: kCIInputIntensityKey)
        
        // Apply subtle chromatic aberration
        let colorControls = CIFilter(name: "CIColorControls")!
        colorControls.setValue(bloomFilter.outputImage, forKey: kCIInputImageKey)
        colorControls.setValue(1.02, forKey: kCIInputSaturationKey)
        colorControls.setValue(1.05, forKey: kCIInputBrightnessKey)
        
        if let outputImage = colorControls.outputImage,
           let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) {
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }
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
