import AVFoundation
import NESCore

/// Pulls samples produced by the emulation thread from a lock-free ring buffer.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let ring: OpaquePointer
    private let gainBox = GainBox()
    private(set) var sampleRate: Double = 48000

    final class GainBox { var value: Float = 0.8 }

    init(ring: OpaquePointer) {
        self.ring = ring
        let hw = engine.outputNode.outputFormat(forBus: 0)
        if hw.sampleRate > 0 { sampleRate = hw.sampleRate }
        // stereo, non-interleaved (one buffer per channel)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let ring = self.ring
        let gain = gainBox
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let left = abl.count > 0 ? abl[0].mData?.assumingMemoryBound(to: Float.self) : nil
            let right = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil
            zr_ring_read_stereo(ring, left, right, frameCount, gain.value)
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0
        do { try engine.start() } catch { NSLog("ZeldaRecomp: audio engine failed to start: \(error)") }
    }

    var volume: Float {
        get { gainBox.value }
        set { gainBox.value = max(0, min(1.5, newValue)) }
    }

    func stop() { engine.stop() }
}
