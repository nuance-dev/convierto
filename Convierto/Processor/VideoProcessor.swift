import AVFoundation
import UniformTypeIdentifiers
import CoreImage
import AppKit
import os
import AudioToolbox

protocol ResourceManaging {
    func cleanup()
}

class VideoProcessor: BaseConverter {
    private weak var processorFactory: ProcessorFactory?
    private let audioVisualizer: AudioVisualizer
    private let imageProcessor: ImageProcessor
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Convierto", category: "VideoProcessor")
    
    required init(settings: ConversionSettings = ConversionSettings()) throws {
        self.audioVisualizer = AudioVisualizer(size: CGSize(width: 1920, height: 1080))
        self.imageProcessor = try ImageProcessor(settings: settings)
        try super.init(settings: settings)
    }
    
    convenience init(settings: ConversionSettings = ConversionSettings(), factory: ProcessorFactory? = nil) throws {
        try self.init(settings: settings)
        self.processorFactory = factory
    }
    
    override func convert(_ url: URL, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        logger.debug("🎬 Starting video conversion")
        let urlPath = url.path(percentEncoded: false)
        logger.debug("📂 Input URL: \(urlPath)")
        logger.debug("🎯 Target format: \(format.identifier)")
        
        let asset = AVURLAsset(url: url)
        logger.debug("✅ Created AVURLAsset")
        
        // If target format is audio, handle audio extraction
        if format.conforms(to: .audio) {
            logger.debug("🎵 Extracting audio from video")
            return try await extractAudio(from: asset, to: format, metadata: metadata, progress: progress)
        }
        
        do {
            logger.debug("⚙️ Attempting primary conversion")
            return try await performConversion(asset: asset, originalURL: url, to: format, metadata: metadata, progress: progress)
        } catch {
            logger.error("❌ Primary conversion failed: \(error.localizedDescription)")
            logger.debug("🔄 Attempting fallback conversion")
            return try await handleFallback(asset: asset, originalURL: url, to: format, metadata: metadata, progress: progress)
        }
    }
    
    override func canConvert(from: UTType, to: UTType) -> Bool {
        switch (from, to) {
        case (let f, _) where f.conforms(to: .audiovisualContent):
            return true
        case (_, let t) where t.conforms(to: .audiovisualContent):
            return true
        default:
            return false
        }
    }
    
    private func handleFallback(
        asset: AVAsset,
        originalURL: URL,
        to format: UTType,
        metadata: ConversionMetadata,
        progress: Progress
    ) async throws -> ProcessingResult {
        if format.conforms(to: .image) {
            return try await extractKeyFrame(from: asset, format: format, metadata: metadata)
        }
        
        // Try with reduced quality settings
        let fallbackSettings = ConversionSettings(
            videoQuality: AVAssetExportPresetMediumQuality,
            videoBitRate: 1_000_000,
            audioBitRate: 64_000,
            frameRate: 24
        )
        
        return try await performConversion(
            asset: asset,
            originalURL: originalURL,
            to: format,
            metadata: metadata,
            progress: progress,
            settings: fallbackSettings
        )
    }
    
    private func performConversion(
        asset: AVAsset,
        originalURL: URL,
        to format: UTType,
        metadata: ConversionMetadata,
        progress: Progress,
        settings: ConversionSettings = ConversionSettings()
    ) async throws -> ProcessingResult {
        logger.debug("⚙️ Starting conversion process")
        
        let outputURL = try CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
        let outputPath = outputURL.path(percentEncoded: false)
        logger.debug("📂 Created temporary output URL: \(outputPath)")
        
        let isAudioOnly = format.conforms(to: .audio)
        guard let exportSession = try? AVAssetExportSession(
            asset: asset, 
            presetName: settings.videoQuality
        ) else {
            throw ConversionError.exportFailed(reason: "Failed to create export session")
        }
        logger.debug("✅ Created export session")
        
        // Configure export session
        exportSession.outputURL = outputURL
        exportSession.outputFileType = getAVFileType(for: format)
        
        // Make exportSession Sendable by isolating it
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    if let audioMix = try await createAudioMix(for: asset) {
                        exportSession.audioMix = audioMix
                        logger.debug("🎵 Applied audio mix")
                    }
                    
                    if format.conforms(to: .audiovisualContent) {
                        let videoComposition = try await createVideoComposition(for: asset)
                        exportSession.videoComposition = videoComposition
                        logger.debug("🎥 Applied video composition")
                    }
                    
                    logger.debug("▶️ Starting export")
                    
                    // Create progress tracking task
                    let progressTask = Task {
                        while !Task.isCancelled {
                            let currentProgress = exportSession.progress
                            progress.completedUnitCount = Int64(currentProgress * 100)
                            logger.debug("📊 Export progress: \(Int(currentProgress * 100))%")
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            if exportSession.status == .completed || exportSession.status == .failed {
                                break
                            }
                        }
                    }
                    
                    // Start export
                    await exportSession.export()
                    progressTask.cancel()
                    
                    if exportSession.status == .completed {
                        logger.debug("✅ Export completed successfully")
                        let result = ProcessingResult(
                            outputURL: outputURL,
                            originalFileName: metadata.originalFileName ?? originalURL.lastPathComponent,
                            suggestedFileName: "converted_video." + (format.preferredFilenameExtension ?? "mp4"),
                            fileType: format,
                            metadata: try await extractMetadata(from: asset)
                        )
                        continuation.resume(returning: result)
                    } else if let error = exportSession.error {
                        logger.error("❌ Export failed: \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: ConversionError.conversionFailed(reason: "Export failed"))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func extractKeyFrame(from asset: AVAsset, format: UTType, metadata: ConversionMetadata) async throws -> ProcessingResult {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        let imageRef = try await generator.image(at: time).image
        
        let outputURL = try CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "jpg")
        let nsImage = NSImage(cgImage: imageRef, size: NSSize(width: imageRef.width, height: imageRef.height))
        
        let imageProcessor = try ImageProcessor()
        try await imageProcessor.saveImage(
            nsImage,
            format: format,
            to: outputURL,
            metadata: metadata
        )
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "frame",
            suggestedFileName: "extracted_frame." + (format.preferredFilenameExtension ?? "jpg"),
            fileType: format,
            metadata: nil
        )
    }
    
    private func createSimpleAnimation(for asset: AVAsset, format: UTType, metadata: ConversionMetadata) async throws -> ProcessingResult {
        // Implementation for creating simple animation
        // This would be called as a fallback when regular conversion fails
        logger.debug("Creating simple animation fallback")
        
        // Extract a frame and create a simple animation from it
        let frame = try await extractKeyFrame(from: asset, format: .jpeg, metadata: metadata)
        guard let image = NSImage(contentsOf: frame.outputURL) else {
            throw ConversionError.conversionFailed(reason: "Failed to load frame image")
        }
        
        return try await imageProcessor.createVideoFromImage(image, format: format, metadata: metadata, progress: Progress())
    }
    
    private func createVideoComposition(for asset: AVAsset) async throws -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.conversionFailed(reason: "No video track found")
        }
        
        let trackSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        
        let targetSize = settings.maintainAspectRatio ? 
            calculateAspectFitSize(trackSize, target: settings.targetSize) :
            settings.targetSize
        
        composition.renderSize = targetSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        composition.renderScale = 1.0
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        
        if settings.brightness != 0.0 {
            layerInstruction.setOpacity(Float(settings.brightness), at: .zero)
        }
        
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        
        return composition
    }
    
    private func calculateAspectFitSize(_ originalSize: CGSize, target: CGSize) -> CGSize {
        let widthRatio = target.width / originalSize.width
        let heightRatio = target.height / originalSize.height
        let scale = min(widthRatio, heightRatio)
        
        return CGSize(
            width: originalSize.width * scale,
            height: originalSize.height * scale
        )
    }
    
    private func extractMetadata(from asset: AVAsset) async throws -> [String: Any] {
        var metadata: [String: Any] = [:]
        
        metadata["duration"] = try await asset.load(.duration).seconds
        metadata["preferredRate"] = try await asset.load(.preferredRate)
        metadata["preferredVolume"] = try await asset.load(.preferredVolume)
        
        if let format = try await asset.load(.availableMetadataFormats).first {
            let items = try await asset.loadMetadata(for: format)
            for item in items {
                if let key = item.commonKey?.rawValue,
                   let value = try? await item.load(.value) {
                    metadata[key] = value
                }
            }
        }
        
        return metadata
    }
    
    internal func createVideoFromImage(_ image: NSImage, format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        logger.debug("🎬 Creating video from image")
        
        let outputURL = try CacheManager.shared.createTemporaryURL(for: format.preferredFilenameExtension ?? "mp4")
        logger.debug("📝 Output URL created: \(outputURL.path)")
        
        let videoWriter = try AVAssetWriter(url: outputURL, fileType: .mp4)
        logger.debug("✅ Created AVAssetWriter")
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(image.size.width),
            AVVideoHeightKey: Int(image.size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        logger.debug("⚙️ Video settings configured: \(videoSettings)")
        
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        logger.debug("✅ Video input configured")
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(image.size.width),
                kCVPixelBufferHeightKey as String: Int(image.size.height)
            ]
        )
        logger.debug("✅ Pixel buffer adaptor configured")
        
        videoWriter.add(videoInput)
        videoWriter.startWriting()
        videoWriter.startSession(atSourceTime: .zero)
        logger.debug("🎬 Started writing session")
        
        // Create a 3-second video
        let frameDuration = CMTimeMake(value: 1, timescale: 30)
        let frameCount = 90 // 3 seconds at 30fps
        logger.debug("⚙️ Configured for \(frameCount) frames at \(30)fps")
        
        for frameIndex in 0..<frameCount {
            if let buffer = try await createPixelBuffer(from: image) {
                logger.debug("✅ Pixel buffer created successfully")
                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
                adaptor.append(buffer, withPresentationTime: presentationTime)
                logger.debug("📝 Writing video frame \(frameIndex + 1)/\(frameCount)")
            }
        }
        
        videoInput.markAsFinished()
        await videoWriter.finishWriting()
        logger.debug("✅ Video writing completed")
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "image",
            suggestedFileName: "converted_video.mp4",
            fileType: format,
            metadata: nil
        )
    }
    
    private func createPixelBuffer(from image: NSImage) async throws -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            logger.error("❌ Failed to create pixel buffer")
            return nil
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
            logger.error("❌ Failed to create CGContext")
            return nil
        }
        
        NSGraphicsContext.saveGraphicsState()
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = nsContext
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        
        return buffer
    }
    
    private func extractAudio(from asset: AVAsset, to format: UTType, metadata: ConversionMetadata, progress: Progress) async throws -> ProcessingResult {
        logger.debug("🎵 Starting audio extraction")
        
        // Verify audio track exists
        guard try await asset.loadTracks(withMediaType: .audio).first != nil else {
            throw ConversionError.conversionFailed(reason: "No audio track found in video")
        }
        
        // First convert to M4A regardless of target format
        let tempURL = try CacheManager.shared.createTemporaryURL(for: "m4a")
        logger.debug("📝 Output URL created: \(tempURL.path)")
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ConversionError.conversionFailed(reason: "Failed to create export session")
        }
        
        exportSession.outputURL = tempURL
        exportSession.outputFileType = .m4a
        
        // Create progress tracking task
        let progressTask = Task {
            while !Task.isCancelled {
                progress.completedUnitCount = Int64(exportSession.progress * 100)
                try? await Task.sleep(nanoseconds: 100_000_000)
                if exportSession.status == .completed || exportSession.status == .failed {
                    break
                }
            }
        }
        
        await exportSession.export()
        progressTask.cancel()
        
        if exportSession.status == .completed {
            logger.debug("✅ Audio extraction completed")
            
            // If MP3 is requested, convert from M4A
            if format == .mp3 {
                logger.debug("🔄 Converting to MP3 format")
                return try await convertToMP3(from: tempURL, metadata: metadata)
            }
            
            // For other formats, just return the M4A result
            return ProcessingResult(
                outputURL: tempURL,
                originalFileName: metadata.originalFileName ?? "audio",
                suggestedFileName: "extracted_audio." + (format.preferredFilenameExtension ?? "m4a"),
                fileType: format,
                metadata: try await extractMetadata(from: asset)
            )
        } else {
            throw ConversionError.exportFailed(reason: "Failed to extract audio: \(exportSession.error?.localizedDescription ?? "Unknown error")")
        }
    }
    
    private func convertToMP3(from url: URL, metadata: ConversionMetadata) async throws -> ProcessingResult {
        logger.debug("🎵 Starting MP3 conversion")
        
        let outputURL = try CacheManager.shared.createTemporaryURL(for: "mp3")
        logger.debug("📝 Created output URL: \(outputURL.path)")
        
        var audioFile: AudioFileID?
        var outputAudioFile: AudioFileID?
        
        // Open input audio file
        var status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        guard status == noErr, let inputFile = audioFile else {
            logger.error("❌ Failed to open input audio file")
            throw ConversionError.conversionFailed(reason: "Failed to open input audio file")
        }
        defer { AudioFileClose(inputFile) }
        
        // Get input file format
        var dataFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioFileGetProperty(inputFile, kAudioFilePropertyDataFormat, &size, &dataFormat)
        guard status == noErr else {
            logger.error("❌ Failed to get input file format")
            throw ConversionError.conversionFailed(reason: "Failed to get input file format")
        }
        
        // Configure output format for MP3
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: dataFormat.mSampleRate,
            mFormatID: kAudioFormatMPEGLayer3,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1152,
            mBytesPerFrame: 0,
            mChannelsPerFrame: dataFormat.mChannelsPerFrame,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        
        // Create audio converter
        var audioConverter: AudioConverterRef?
        status = AudioConverterNew(&dataFormat, &outputFormat, &audioConverter)
        guard status == noErr, let converter = audioConverter else {
            logger.error("❌ Failed to create audio converter")
            throw ConversionError.conversionFailed(reason: "Failed to create audio converter")
        }
        defer { AudioConverterDispose(converter) }
        
        // Create output file
        status = AudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileMP3Type,
            &outputFormat,
            .eraseFile,
            &outputAudioFile
        )
        guard status == noErr, let outputFile = outputAudioFile else {
            logger.error("❌ Failed to create output audio file")
            throw ConversionError.conversionFailed(reason: "Failed to create output audio file")
        }
        defer { AudioFileClose(outputFile) }
        
        // Set up conversion buffers
        let bufferSize = 32768
        var inputBuffer = [UInt8](repeating: 0, count: bufferSize)
        var audioBufferData = AudioBufferData(
            data: &inputBuffer,
            size: bufferSize
        )
        
        // Perform conversion
        var outputBuffer = [UInt8](repeating: 0, count: bufferSize)
        var outputBufferList = AudioBufferList()
        outputBufferList.mNumberBuffers = 1
        outputBufferList.mBuffers.mNumberChannels = outputFormat.mChannelsPerFrame
        outputBufferList.mBuffers.mDataByteSize = UInt32(bufferSize)
        
        // Safely bind the output buffer
        withUnsafeMutableBytes(of: &outputBuffer) { bufferPointer in
            outputBufferList.mBuffers.mData = bufferPointer.baseAddress
        }
        
        var outputFilePos: Int64 = 0
        
        repeat {
            var numPackets: UInt32 = UInt32(bufferSize / MemoryLayout<UInt8>.stride)
            status = AudioConverterFillComplexBuffer(
                converter,
                converterCallback,
                &audioBufferData,
                &numPackets,
                &outputBufferList,
                nil
            )
            
            if numPackets > 0 {
                status = AudioFileWritePackets(
                    outputFile,
                    false,
                    outputBufferList.mBuffers.mDataByteSize,
                    nil,
                    outputFilePos,
                    &numPackets,
                    &outputBuffer
                )
                outputFilePos += Int64(numPackets)
            }
        } while status == noErr
        
        return ProcessingResult(
            outputURL: outputURL,
            originalFileName: metadata.originalFileName ?? "audio",
            suggestedFileName: "converted_audio.mp3",
            fileType: .mp3,
            metadata: metadata.toDictionary()
        )
    }
    
    // Audio converter callback function
    private let converterCallback: AudioConverterComplexInputDataProc = { (
        _: AudioConverterRef,
        ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
        ioData: UnsafeMutablePointer<AudioBufferList>,
        _: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
        inUserData: UnsafeMutableRawPointer?
    ) -> OSStatus in
        guard let userData = inUserData else {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        
        let audioData = userData.assumingMemoryBound(to: AudioBufferData.self).pointee
        
        if audioData.size == 0 {
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        
        // Directly modify the AudioBufferList instead of using UnsafeMutableAudioBufferListPointer
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(audioData.data)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(audioData.size)
        ioData.pointee.mBuffers.mNumberChannels = 2
        
        return noErr
    }
    
    // Add this struct to store audio buffer data
    private struct AudioBufferData {
        var data: UnsafeMutablePointer<UInt8>
        var size: Int
        
        init(data: UnsafeMutablePointer<UInt8>, size: Int) {
            self.data = data
            self.size = size
        }
    }
}
