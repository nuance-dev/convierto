import AVFoundation
import CoreGraphics
import AppKit

class AudioVisualizer {
    private let size: CGSize
    private let settings = ConversionSettings()
    
    init(size: CGSize) {
        self.size = size
    }
    
    func generateWaveformImage(for asset: AVAsset) async throws -> NSImage {
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.invalidInput
        }
        
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw ConversionError.conversionFailed
        }
        
        // Create audio mix output with optional binding
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        
        let output = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: audioSettings)
        guard reader.canAdd(output) else {
            throw ConversionError.conversionFailed
        }
        
        reader.add(output)
        reader.startReading()
        
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let channelData = AVAudioPCMBuffer(pcmFormat: .init(standardFormatWithSampleRate: 44100, channels: 1)!,
                                                    frameCapacity: 1024) else {
                continue
            }
            
            var bufferList = AudioBufferList()
            var blockBuffer: CMBlockBuffer?
            
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                buffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: &bufferList,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            
            let bufferLength = Int(channelData.frameLength)
            if let data = channelData.floatChannelData?[0] {
                samples.append(contentsOf: Array(UnsafeBufferPointer(start: data, count: bufferLength)))
            }
        }
        
        // Generate waveform image
        let renderer = NSImage(size: size)
        renderer.lockFocus()
        
        NSColor.black.set()
        NSRect(origin: .zero, size: size).fill()
        
        NSColor.systemBlue.set()
        drawWaveform(samples, in: NSRect(origin: .zero, size: size))
        
        renderer.unlockFocus()
        return renderer
    }
    
    private func drawWaveform(_ samples: [Float], in rect: NSRect) {
        let path = NSBezierPath()
        let step = rect.width / CGFloat(samples.count - 1)
        let scale = rect.height / 2
        
        path.move(to: NSPoint(x: 0, y: rect.midY))
        
        for (index, sample) in samples.enumerated() {
            let x = CGFloat(index) * step
            let y = rect.midY + CGFloat(sample) * scale
            path.line(to: NSPoint(x: x, y: y))
        }
        
        path.stroke()
    }
}