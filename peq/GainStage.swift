import Foundation

enum GainStage {
    static func protectedGlobalGainDb(for settings: EQSettings) -> Double {
        let outputGain = EQLimits.clamp(settings.outputGainDb, to: EQLimits.outputGainDb)
        return outputGain - positiveBoostHeadroomDb(for: settings)
    }

    static func effectivePreampDb(for settings: EQSettings) -> Double {
        -positiveBoostHeadroomDb(for: settings)
    }

    static func effectiveBandGainDb(for band: EQBand, settings: EQSettings) -> Double {
        guard !settings.bypass, band.enabled else { return 0 }
        return EQLimits.clamp(band.gainDb, to: EQLimits.bandGainDb)
    }

    private static func positiveBoostHeadroomDb(for settings: EQSettings) -> Double {
        guard !settings.bypass else { return 0 }

        return settings.bands.reduce(0) { headroom, band in
            guard band.enabled else { return headroom }
            let gain = EQLimits.clamp(band.gainDb, to: EQLimits.bandGainDb)
            return headroom + max(0, gain)
        }
    }
}
