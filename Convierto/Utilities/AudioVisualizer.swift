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
        frameCount: Int
    ) async throws -> [CGImage] {
        logger.debug("Generating visualization frames")
        var frames: [CGImage] = []
        let duration = try await asset.load(.duration)
        let timeStep = duration.seconds / Double(frameCount)
        
        for frameIndex in 0..<frameCount {
            let time = CMTime(seconds: Double(frameIndex) * timeStep, preferredTimescale: 600)
            let samples = try await extractAudioSamples(from: asset, at: time, windowSize: timeStep)
            
            if let frame = try await generateVisualizationFrame(from: samples) {
                frames.append(frame)
            }
            
            if frameIndex % 10 == 0 {
                logger.debug("Generated frame \(frameIndex)/\(frameCount)")
            }
        }
        
        return frames
    }
    
    private func extractAudioSamples(from asset: AVAsset, at time: CMTime, windowSize: Double) async throws -> [Float] {
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.invalidInput
        }
        
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 44100
        ]
        
        let output = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: outputSettings)
        reader.timeRange = CMTimeRange(start: time, duration: CMTime(seconds: windowSize, preferredTimescale: 600))
        
        guard reader.canAdd(output) else {
            throw ConversionError.conversionFailed
        }
        
        reader.add(output)
        reader.startReading()
        
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            let audioBuffer = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: nil,
                bufferListSize: 0,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: nil
            )
            
            if let blockBuffer = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &dataPointer
                )
                
                if let pointer = dataPointer {
                    let bufferPointer = UnsafeBufferPointer<Float>(
                        start: UnsafePointer<Float>(OpaquePointer(pointer)),
                        count: length / MemoryLayout<Float>.stride
                    )
                    samples.append(contentsOf: bufferPointer)
                }
            }
        }
        
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
        settings: ConversionSettings
    ) async throws -> AVAssetTrack {
        let frameURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        
        let writer = try AVAssetWriter(url: frameURL, fileType: .mov)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writer.add(input)
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB)
            ]
        )
        
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        let frameDuration = CMTime(value: duration.value / Int64(frames.count), timescale: duration.timescale)
        
        for (index, frame) in frames.enumerated() {
            if let buffer = try await createPixelBuffer(from: frame) {
                let presentationTime = CMTime(value: Int64(index) * frameDuration.value, timescale: frameDuration.timescale)
                adaptor.append(buffer, withPresentationTime: presentationTime)
            }
        }
        
        input.markAsFinished()
        await writer.finishWriting()
        
        let asset = AVAsset(url: frameURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.conversionFailed
        }
        
        return videoTrack
    }
    
    func generateWaveformImage(for asset: AVAsset, size: CGSize) async throws -> CGImage {
        let samples = try await extractAudioSamples(from: asset, at: .zero, windowSize: try await asset.load(.duration).seconds)
        
        guard let frame = try await generateVisualizationFrame(from: samples) else {
            throw ConversionError.conversionFailed
        }
        
        return frame
    }
    
    private func createPixelBuffer(from image: CGImage) async throws -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let width = image.width
        let height = image.height
        
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            nil,
            &pixelBuffer
        )
        
        guard let buffer = pixelBuffer else { return nil }
        
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
            return nil
        }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
