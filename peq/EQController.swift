import AVFoundation

final class EQController {
    let unit: AVAudioUnitEQ

    private let queue = DispatchQueue(label: "com.arbisoft.peq.eq-controller")
    private var appliedSettings: EQSettings
    private var rampGeneration = 0

    init(settings: EQSettings) {
        let sanitizedSettings = settings.sanitized()
        self.appliedSettings = sanitizedSettings
        self.unit = AVAudioUnitEQ(numberOfBands: sanitizedSettings.bands.count)
        applyImmediately(sanitizedSettings)
    }

    func apply(_ settings: EQSettings) {
        let sanitizedSettings = settings.sanitized()

        queue.async { [weak self] in
            guard let self else { return }

            let previous = self.appliedSettings
            self.appliedSettings = sanitizedSettings
            self.rampGeneration += 1
            self.ramp(from: previous, to: sanitizedSettings, generation: self.rampGeneration)
        }
    }

    func applyImmediately(_ settings: EQSettings) {
        let sanitizedSettings = settings.sanitized()
        unit.globalGain = Float(GainStage.protectedGlobalGainDb(for: sanitizedSettings))

        for (index, band) in sanitizedSettings.bands.enumerated() where index < unit.bands.count {
            let target = unit.bands[index]
            target.filterType = .parametric
            target.frequency = Float(EQLimits.clamp(band.frequencyHz, to: EQLimits.frequencyHz))
            target.gain = Float(GainStage.effectiveBandGainDb(for: band, settings: sanitizedSettings))
            target.bandwidth = Float(EQLimits.clamp(band.bandwidth, to: EQLimits.bandwidth))
            target.bypass = false
        }
    }

    private func ramp(from previous: EQSettings, to next: EQSettings, generation: Int) {
        let steps = 6
        let delay: TimeInterval = 0.008

        for step in 1...steps {
            let amount = Double(step) / Double(steps)
            queue.asyncAfter(deadline: .now() + delay * Double(step)) { [weak self] in
                guard let self else { return }
                guard generation == self.rampGeneration else { return }
                self.applyInterpolated(from: previous, to: next, amount: amount)
            }
        }
    }

    private func applyInterpolated(from previous: EQSettings, to next: EQSettings, amount: Double) {
        let previousGlobalGain = GainStage.protectedGlobalGainDb(for: previous)
        let nextGlobalGain = GainStage.protectedGlobalGainDb(for: next)
        unit.globalGain = Float(Self.interpolate(previousGlobalGain, nextGlobalGain, amount: amount))

        for index in 0..<min(next.bands.count, unit.bands.count) {
            let target = unit.bands[index]
            let nextBand = next.bands[index]
            let previousBand = index < previous.bands.count ? previous.bands[index] : nextBand

            let previousGain = GainStage.effectiveBandGainDb(for: previousBand, settings: previous)
            let nextGain = GainStage.effectiveBandGainDb(for: nextBand, settings: next)

            target.filterType = .parametric
            target.frequency = Float(Self.interpolate(previousBand.frequencyHz, nextBand.frequencyHz, amount: amount))
            target.gain = Float(Self.interpolate(previousGain, nextGain, amount: amount))
            target.bandwidth = Float(Self.interpolate(previousBand.bandwidth, nextBand.bandwidth, amount: amount))
            target.bypass = false
        }
    }

    private static func interpolate(_ start: Double, _ end: Double, amount: Double) -> Double {
        start + ((end - start) * amount)
    }
}
