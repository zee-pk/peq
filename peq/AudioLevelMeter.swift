import AVFoundation

final class AudioLevelMeter {
    private let lastPeak = AtomicFloat(0)
    private let healthStore: AudioHealthStore

    init(healthStore: AudioHealthStore) {
        self.healthStore = healthStore
    }

    var currentPeak: Float { lastPeak.load() }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else {
            lastPeak.store(0)
            healthStore.storeOutputPeak(0)
            return
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var peak: Float = 0

        for channelIndex in 0..<channelCount {
            let channel = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                peak = max(peak, abs(channel[frameIndex]))
            }
        }

        lastPeak.store(peak)
        healthStore.storeOutputPeak(peak)
    }
}
