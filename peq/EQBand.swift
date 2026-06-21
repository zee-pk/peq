import Foundation

enum EQLimits {
    static let outputGainDb = -30.0...0.0
    static let bandGainDb = -24.0...12.0
    static let frequencyHz = 20.0...20_000.0
    static let bandwidth = 0.05...5.0

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

struct EQBand: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var enabled: Bool
    var frequencyHz: Double
    var gainDb: Double
    var bandwidth: Double

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        frequencyHz: Double,
        gainDb: Double = 0,
        bandwidth: Double = 0.5
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.frequencyHz = frequencyHz
        self.gainDb = gainDb
        self.bandwidth = bandwidth
    }
}

struct EQSettings: Codable, Equatable {
    var bypass: Bool
    var outputGainDb: Double
    var targetOutputDeviceUID: String?
    var targetOutputDeviceName: String?
    var bands: [EQBand]

    static func newBand(number: Int, frequencyHz: Double = 1_000) -> EQBand {
        EQBand(name: "Band \(number)", frequencyHz: frequencyHz, bandwidth: 0.8)
    }

    static let flat = EQSettings(
        bypass: false,
        outputGainDb: -3,
        targetOutputDeviceUID: nil,
        targetOutputDeviceName: nil,
        bands: [
            EQBand(name: "Band 1", frequencyHz: 105, bandwidth: 0.7),
            EQBand(name: "Band 2", frequencyHz: 1_000, bandwidth: 0.8),
            EQBand(name: "Band 3", frequencyHz: 8_000, bandwidth: 0.7)
        ]
    )

    func sanitized() -> EQSettings {
        var copy = self
        copy.outputGainDb = EQLimits.clamp(copy.outputGainDb, to: EQLimits.outputGainDb)
        copy.targetOutputDeviceUID = copy.targetOutputDeviceUID?.isEmpty == true ? nil : copy.targetOutputDeviceUID
        copy.targetOutputDeviceName = copy.targetOutputDeviceName?.isEmpty == true ? nil : copy.targetOutputDeviceName

        if copy.targetOutputDeviceUID == nil {
            copy.targetOutputDeviceName = nil
        }

        if copy.bands.isEmpty {
            copy.bands = EQSettings.flat.bands
        }

        for index in copy.bands.indices {
            copy.bands[index].name = copy.bands[index].name.isEmpty ? "Band \(index + 1)" : copy.bands[index].name
            copy.bands[index].frequencyHz = EQLimits.clamp(copy.bands[index].frequencyHz, to: EQLimits.frequencyHz)
            copy.bands[index].gainDb = EQLimits.clamp(copy.bands[index].gainDb, to: EQLimits.bandGainDb)
            copy.bands[index].bandwidth = EQLimits.clamp(copy.bands[index].bandwidth, to: EQLimits.bandwidth)
        }

        return copy
    }
}
