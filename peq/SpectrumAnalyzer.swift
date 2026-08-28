import Accelerate
import AppKit
import AVFoundation
import Atomics
import Darwin
import SwiftUI

enum SpectrumAnalyzerTuning {
    static let minimumFrequency: Float = 20
    static let maximumFrequency: Float = 20_000
    static let defaultFFTSize = 8_192
    static let defaultSnapshotHopFrames = 256
    static let defaultRefreshIntervalMilliseconds = 1
    static let defaultBandCount = 32
    static let defaultBandGapPixels: CGFloat = 8
    static let defaultPeakHoldSeconds = 0.50
    static let defaultMinimumDb = -90.0
    static let defaultMaximumDb = 0.0
    static let defaultBandFallDbPerSecond = 45.0
    static let defaultPeakFallDbPerSecond = 18.0
    static let fallRateRange: ClosedRange<Double> = 1...240
    static let defaultBandSeparation = 0.35
    static let bandSeparationRange: ClosedRange<Double> = 0...0.8

    static func centerFrequency(forBand index: Int, bandCount: Int) -> Float {
        guard bandCount > 0 else { return minimumFrequency }
        return minimumFrequency * powf(maximumFrequency / minimumFrequency, (Float(index) + 0.5) / Float(bandCount))
    }

    static func dbTicks(minimum: Float, maximum: Float) -> [Float] {
        // Aim for roughly eight divisions: the default -90...0 range therefore retains 12 dB spacing.
        let desiredStep = (maximum - minimum) / 8
        let step: Float = [1, 2, 3, 6, 12, 24, 48].first(where: { $0 >= desiredStep }) ?? 48
        var ticks = [minimum]
        var tick = ceil(minimum / step) * step
        while tick < maximum {
            if tick > minimum { ticks.append(tick) }
            tick += step
        }
        ticks.append(maximum)
        return ticks
    }
}

enum SpectrumLayoutMode: String, Codable, CaseIterable, Identifiable {
    case fullSpectrum
    case trackInfoAndSpectrum

    var id: Self { self }

    var title: String {
        switch self {
        case .fullSpectrum: "Full Spectrum"
        case .trackInfoAndSpectrum: "Track Info + Spectrum"
        }
    }
}

enum SpectrumAudioSource: String, Codable, CaseIterable, Identifiable {
    case preEQ
    case postEQ

    var id: Self { self }

    var title: String {
        switch self {
        case .preEQ: "Pre-EQ"
        case .postEQ: "Post-EQ"
        }
    }

    fileprivate var atomicValue: Int {
        switch self {
        case .preEQ: 0
        case .postEQ: 1
        }
    }
}

/// Stored independently from EQ presets because it controls the analyzer rather than audio processing.
struct SpectrumLEDRegion: Codable, Identifiable, Equatable {
    var id = UUID()
    var colorRGB: [Double]
    /// Number of LED rows in this region. The final region always uses the remaining rows.
    var rowCount: Int?
}

struct SpectrumAnalyzerSettings: Codable, Equatable {
    var layoutMode = SpectrumLayoutMode.fullSpectrum
    var audioSource = SpectrumAudioSource.postEQ
    var fftSize = SpectrumAnalyzerTuning.defaultFFTSize
    var snapshotHopFrames = SpectrumAnalyzerTuning.defaultSnapshotHopFrames
    var refreshIntervalMilliseconds = SpectrumAnalyzerTuning.defaultRefreshIntervalMilliseconds
    var bandCount = SpectrumAnalyzerTuning.defaultBandCount
    var bandGapPixels = Double(SpectrumAnalyzerTuning.defaultBandGapPixels)
    var peakHoldSeconds = SpectrumAnalyzerTuning.defaultPeakHoldSeconds
    var minimumDb = SpectrumAnalyzerTuning.defaultMinimumDb
    var maximumDb = SpectrumAnalyzerTuning.defaultMaximumDb
    var bandFallDbPerSecond = SpectrumAnalyzerTuning.defaultBandFallDbPerSecond
    var peakFallDbPerSecond = SpectrumAnalyzerTuning.defaultPeakFallDbPerSecond
    var bandSeparation = SpectrumAnalyzerTuning.defaultBandSeparation
    var peakMarkerRGB = [0.78, 0.78, 0.78]
    var hidePlotLabelsWhenIdle = true
    var darkRedRGB = [0.72, 0.015, 0.025]
    var orangeRedRGB = [1.0, 0.12, 0.035]
    var orangeRGB = [1.0, 0.42, 0.04]
    var yellowRGB = [1.0, 0.86, 0.12]
    var darkRedRegionPercent = 15.0
    var orangeRedRegionPercent = 20.0
    var orangeRegionPercent = 20.0
    var yellowRegionPercent = 25.0
    var ledRegions = [
        SpectrumLEDRegion(colorRGB: [0.72, 0.015, 0.025], rowCount: 8),
        SpectrumLEDRegion(colorRGB: [1.0, 0.12, 0.035], rowCount: 10),
        SpectrumLEDRegion(colorRGB: [1.0, 0.42, 0.04], rowCount: 10),
        SpectrumLEDRegion(colorRGB: [1.0, 0.86, 0.12], rowCount: nil)
    ]
    var ledSegmentCount = 40.0
    var ledGapPercent = 20.0

    static let fftSizes = [2_048, 4_096, 8_192, 16_384]
    static let bandCountRange = 8...128
    static let hopFrameRange = 32...2_048
    static let refreshIntervalRange = 1...100
    static let bandGapRange = 0.0...24.0
    static let peakHoldRange = 0.0...5.0
    static let minimumDbRange = -120.0...(-6.0)
    static let maximumDbRange = -60.0...24.0
    static let minimumDbSpan = 12.0
    static let ledSegmentRange = 4.0...160.0
    static let ledRegionCountRange = 1...10
    static let percentageRange = 0.0...100.0

    mutating func sanitize() {
        if !Self.fftSizes.contains(fftSize) { fftSize = SpectrumAnalyzerTuning.defaultFFTSize }
        snapshotHopFrames = min(max(snapshotHopFrames, Self.hopFrameRange.lowerBound), min(Self.hopFrameRange.upperBound, fftSize))
        refreshIntervalMilliseconds = min(max(refreshIntervalMilliseconds, Self.refreshIntervalRange.lowerBound), Self.refreshIntervalRange.upperBound)
        bandCount = min(max(bandCount, Self.bandCountRange.lowerBound), Self.bandCountRange.upperBound)
        bandGapPixels = min(max(bandGapPixels, Self.bandGapRange.lowerBound), Self.bandGapRange.upperBound)
        peakHoldSeconds = min(max(peakHoldSeconds, Self.peakHoldRange.lowerBound), Self.peakHoldRange.upperBound)
        minimumDb = min(max(minimumDb, Self.minimumDbRange.lowerBound), Self.minimumDbRange.upperBound)
        maximumDb = min(max(maximumDb, Self.maximumDbRange.lowerBound), Self.maximumDbRange.upperBound)
        if maximumDb - minimumDb < Self.minimumDbSpan {
            maximumDb = min(Self.maximumDbRange.upperBound, minimumDb + Self.minimumDbSpan)
            minimumDb = max(Self.minimumDbRange.lowerBound, maximumDb - Self.minimumDbSpan)
        }
        bandFallDbPerSecond = min(max(bandFallDbPerSecond, SpectrumAnalyzerTuning.fallRateRange.lowerBound), SpectrumAnalyzerTuning.fallRateRange.upperBound)
        peakFallDbPerSecond = min(max(peakFallDbPerSecond, SpectrumAnalyzerTuning.fallRateRange.lowerBound), SpectrumAnalyzerTuning.fallRateRange.upperBound)
        bandSeparation = min(max(bandSeparation, SpectrumAnalyzerTuning.bandSeparationRange.lowerBound), SpectrumAnalyzerTuning.bandSeparationRange.upperBound)
        peakMarkerRGB = Self.sanitizedColor(peakMarkerRGB)
        darkRedRGB = Self.sanitizedColor(darkRedRGB)
        orangeRedRGB = Self.sanitizedColor(orangeRedRGB)
        orangeRGB = Self.sanitizedColor(orangeRGB)
        yellowRGB = Self.sanitizedColor(yellowRGB)
        darkRedRegionPercent = Self.clampPercent(darkRedRegionPercent)
        orangeRedRegionPercent = Self.clampPercent(orangeRedRegionPercent)
        orangeRegionPercent = Self.clampPercent(orangeRegionPercent)
        yellowRegionPercent = Self.clampPercent(yellowRegionPercent)
        ledSegmentCount = min(max(ledSegmentCount.rounded(), Self.ledSegmentRange.lowerBound), Self.ledSegmentRange.upperBound)
        ledGapPercent = Self.clampPercent(ledGapPercent)
        sanitizeLEDRegions()
    }

    private mutating func sanitizeLEDRegions() {
        let totalRows = Int(ledSegmentCount)
        let maximumRegionCount = min(Self.ledRegionCountRange.upperBound, totalRows)
        if ledRegions.isEmpty {
            ledRegions = [SpectrumLEDRegion(colorRGB: Self.defaultLEDColors[0], rowCount: nil)]
        }
        ledRegions = Array(ledRegions.prefix(maximumRegionCount))
        for index in ledRegions.indices {
            ledRegions[index].colorRGB = Self.sanitizedColor(ledRegions[index].colorRGB)
        }

        var remainingRows = totalRows
        for index in ledRegions.indices.dropLast() {
            let laterRegionCount = ledRegions.count - index - 1
            let maximumRows = max(1, remainingRows - laterRegionCount)
            let requestedRows = ledRegions[index].rowCount ?? max(1, remainingRows / (laterRegionCount + 1))
            let rows = min(max(1, requestedRows), maximumRows)
            ledRegions[index].rowCount = rows
            remainingRows -= rows
        }
        ledRegions[ledRegions.index(before: ledRegions.endIndex)].rowCount = nil
    }

    mutating func setLEDRegionCount(_ requestedCount: Int) {
        sanitize()
        let totalRows = Int(ledSegmentCount)
        let targetCount = min(max(requestedCount, Self.ledRegionCountRange.lowerBound), min(Self.ledRegionCountRange.upperBound, totalRows))
        if targetCount < ledRegions.count {
            ledRegions.removeLast(ledRegions.count - targetCount)
        } else {
            while ledRegions.count < targetCount {
                let finalIndex = ledRegions.index(before: ledRegions.endIndex)
                let allocatedRows = ledRegions.dropLast().compactMap(\.rowCount).reduce(0, +)
                let remainingRows = max(1, totalRows - allocatedRows)
                ledRegions[finalIndex].rowCount = max(1, remainingRows / 2)
                let color = ledRegions[finalIndex].colorRGB
                ledRegions.append(SpectrumLEDRegion(colorRGB: color, rowCount: nil))
            }
        }
        sanitizeLEDRegions()
    }

    mutating func setLEDRegionRowCount(_ rowCount: Int, id: UUID) {
        guard let index = ledRegions.firstIndex(where: { $0.id == id }), index < ledRegions.count - 1 else { return }
        ledRegions[index].rowCount = rowCount
        sanitizeLEDRegions()
    }

    mutating func setLEDRowCount(_ rowCount: Double) {
        ledSegmentCount = rowCount
        sanitize()
    }

    static func sanitizedColor(_ color: [Double]) -> [Double] {
        (0..<3).map { index in min(1, max(0, color.indices.contains(index) ? color[index] : 0)) }
    }
    private static func clampPercent(_ value: Double) -> Double { min(100, max(0, value)) }

    private static let defaultLEDColors = [
        [0.72, 0.015, 0.025], [1.0, 0.12, 0.035], [1.0, 0.42, 0.04], [1.0, 0.86, 0.12]
    ]

    static func migratedLEDRegions(colors: [[Double]], relativeSizes: [Double], rowCount: Int) -> [SpectrumLEDRegion] {
        let safeRowCount = max(1, rowCount)
        let sizes = relativeSizes.map { $0.isFinite ? max(0, $0) : 0 }
        let total = sizes.reduce(0, +)
        guard !colors.isEmpty, total > 0 else {
            return [SpectrumLEDRegion(colorRGB: defaultLEDColors[0], rowCount: nil)]
        }
        var previousBoundary = 0
        return colors.enumerated().map { index, color in
            guard index < colors.count - 1 else {
                return SpectrumLEDRegion(colorRGB: sanitizedColor(color), rowCount: nil)
            }
            let cumulative = sizes.prefix(index + 1).reduce(0, +) / total
            let minimumBoundary = previousBoundary + 1
            let rowsNeededAfter = colors.count - index - 1
            let maximumBoundary = max(minimumBoundary, safeRowCount - rowsNeededAfter)
            let boundary = min(maximumBoundary, max(minimumBoundary, Int((cumulative * Double(safeRowCount)).rounded())))
            defer { previousBoundary = boundary }
            return SpectrumLEDRegion(colorRGB: sanitizedColor(color), rowCount: boundary - previousBoundary)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case layoutMode, audioSource, fftSize, snapshotHopFrames, refreshIntervalMilliseconds, bandCount, bandGapPixels, peakHoldSeconds, minimumDb, maximumDb, bandFallDbPerSecond, peakFallDbPerSecond, bandSeparation, peakMarkerRGB, hidePlotLabelsWhenIdle, darkRedRGB, orangeRedRGB, orangeRGB, yellowRGB, darkRedRegionPercent, orangeRedRegionPercent, orangeRegionPercent, yellowRegionPercent, ledRegions, ledSegmentCount, ledGapPercent
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var settings = Self()
        settings.layoutMode = try container.decodeIfPresent(SpectrumLayoutMode.self, forKey: .layoutMode) ?? settings.layoutMode
        settings.audioSource = try container.decodeIfPresent(SpectrumAudioSource.self, forKey: .audioSource) ?? settings.audioSource
        settings.fftSize = try container.decodeIfPresent(Int.self, forKey: .fftSize) ?? settings.fftSize
        settings.snapshotHopFrames = try container.decodeIfPresent(Int.self, forKey: .snapshotHopFrames) ?? settings.snapshotHopFrames
        settings.refreshIntervalMilliseconds = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMilliseconds) ?? settings.refreshIntervalMilliseconds
        settings.bandCount = try container.decodeIfPresent(Int.self, forKey: .bandCount) ?? settings.bandCount
        settings.bandGapPixels = try container.decodeIfPresent(Double.self, forKey: .bandGapPixels) ?? settings.bandGapPixels
        settings.peakHoldSeconds = try container.decodeIfPresent(Double.self, forKey: .peakHoldSeconds) ?? settings.peakHoldSeconds
        settings.minimumDb = try container.decodeIfPresent(Double.self, forKey: .minimumDb) ?? settings.minimumDb
        settings.maximumDb = try container.decodeIfPresent(Double.self, forKey: .maximumDb) ?? settings.maximumDb
        settings.bandFallDbPerSecond = try container.decodeIfPresent(Double.self, forKey: .bandFallDbPerSecond) ?? settings.bandFallDbPerSecond
        settings.peakFallDbPerSecond = try container.decodeIfPresent(Double.self, forKey: .peakFallDbPerSecond) ?? settings.peakFallDbPerSecond
        settings.bandSeparation = try container.decodeIfPresent(Double.self, forKey: .bandSeparation) ?? settings.bandSeparation
        settings.peakMarkerRGB = try container.decodeIfPresent([Double].self, forKey: .peakMarkerRGB) ?? settings.peakMarkerRGB
        settings.hidePlotLabelsWhenIdle = try container.decodeIfPresent(Bool.self, forKey: .hidePlotLabelsWhenIdle) ?? settings.hidePlotLabelsWhenIdle
        settings.darkRedRGB = try container.decodeIfPresent([Double].self, forKey: .darkRedRGB) ?? settings.darkRedRGB
        settings.orangeRedRGB = try container.decodeIfPresent([Double].self, forKey: .orangeRedRGB) ?? settings.orangeRedRGB
        settings.orangeRGB = try container.decodeIfPresent([Double].self, forKey: .orangeRGB) ?? settings.orangeRGB
        settings.yellowRGB = try container.decodeIfPresent([Double].self, forKey: .yellowRGB) ?? settings.yellowRGB
        settings.darkRedRegionPercent = try container.decodeIfPresent(Double.self, forKey: .darkRedRegionPercent) ?? settings.darkRedRegionPercent
        settings.orangeRedRegionPercent = try container.decodeIfPresent(Double.self, forKey: .orangeRedRegionPercent) ?? settings.orangeRedRegionPercent
        settings.orangeRegionPercent = try container.decodeIfPresent(Double.self, forKey: .orangeRegionPercent) ?? settings.orangeRegionPercent
        settings.yellowRegionPercent = try container.decodeIfPresent(Double.self, forKey: .yellowRegionPercent) ?? settings.yellowRegionPercent
        settings.ledSegmentCount = try container.decodeIfPresent(Double.self, forKey: .ledSegmentCount) ?? settings.ledSegmentCount
        settings.ledGapPercent = try container.decodeIfPresent(Double.self, forKey: .ledGapPercent) ?? settings.ledGapPercent
        if let regions = try container.decodeIfPresent([SpectrumLEDRegion].self, forKey: .ledRegions), !regions.isEmpty {
            settings.ledRegions = regions
        } else {
            settings.ledRegions = Self.migratedLEDRegions(
                colors: [settings.darkRedRGB, settings.orangeRedRGB, settings.orangeRGB, settings.yellowRGB],
                relativeSizes: [settings.darkRedRegionPercent, settings.orangeRedRegionPercent, settings.orangeRegionPercent, settings.yellowRegionPercent],
                rowCount: Int(settings.ledSegmentCount.rounded())
            )
        }
        settings.sanitize()
        self = settings
    }
}

struct SpectrumLEDProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var darkRedRGB: [Double]
    var orangeRedRGB: [Double]
    var orangeRGB: [Double]
    var yellowRGB: [Double]
    var darkRedRegionPercent: Double
    var orangeRedRegionPercent: Double
    var orangeRegionPercent: Double
    var yellowRegionPercent: Double
    var ledRegions: [SpectrumLEDRegion]
    var ledSegmentCount: Double
    var ledGapPercent: Double

    init(name: String, settings: SpectrumAnalyzerSettings) {
        self.name = name
        darkRedRGB = settings.darkRedRGB
        orangeRedRGB = settings.orangeRedRGB
        orangeRGB = settings.orangeRGB
        yellowRGB = settings.yellowRGB
        darkRedRegionPercent = settings.darkRedRegionPercent
        orangeRedRegionPercent = settings.orangeRedRegionPercent
        orangeRegionPercent = settings.orangeRegionPercent
        yellowRegionPercent = settings.yellowRegionPercent
        ledRegions = settings.ledRegions
        ledSegmentCount = settings.ledSegmentCount
        ledGapPercent = settings.ledGapPercent
    }

    func applying(to settings: inout SpectrumAnalyzerSettings) {
        settings.darkRedRGB = darkRedRGB
        settings.orangeRedRGB = orangeRedRGB
        settings.orangeRGB = orangeRGB
        settings.yellowRGB = yellowRGB
        settings.darkRedRegionPercent = darkRedRegionPercent
        settings.orangeRedRegionPercent = orangeRedRegionPercent
        settings.orangeRegionPercent = orangeRegionPercent
        settings.yellowRegionPercent = yellowRegionPercent
        settings.ledRegions = ledRegions
        settings.ledSegmentCount = ledSegmentCount
        settings.ledGapPercent = ledGapPercent
        settings.sanitize()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, darkRedRGB, orangeRedRGB, orangeRGB, yellowRGB, darkRedRegionPercent, orangeRedRegionPercent, orangeRegionPercent, yellowRegionPercent, ledRegions, ledSegmentCount, ledGapPercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        let defaults = SpectrumAnalyzerSettings()
        darkRedRGB = try container.decodeIfPresent([Double].self, forKey: .darkRedRGB) ?? defaults.darkRedRGB
        orangeRedRGB = try container.decodeIfPresent([Double].self, forKey: .orangeRedRGB) ?? defaults.orangeRedRGB
        orangeRGB = try container.decodeIfPresent([Double].self, forKey: .orangeRGB) ?? defaults.orangeRGB
        yellowRGB = try container.decodeIfPresent([Double].self, forKey: .yellowRGB) ?? defaults.yellowRGB
        darkRedRegionPercent = try container.decodeIfPresent(Double.self, forKey: .darkRedRegionPercent) ?? defaults.darkRedRegionPercent
        orangeRedRegionPercent = try container.decodeIfPresent(Double.self, forKey: .orangeRedRegionPercent) ?? defaults.orangeRedRegionPercent
        orangeRegionPercent = try container.decodeIfPresent(Double.self, forKey: .orangeRegionPercent) ?? defaults.orangeRegionPercent
        yellowRegionPercent = try container.decodeIfPresent(Double.self, forKey: .yellowRegionPercent) ?? defaults.yellowRegionPercent
        ledSegmentCount = try container.decodeIfPresent(Double.self, forKey: .ledSegmentCount) ?? defaults.ledSegmentCount
        ledGapPercent = try container.decodeIfPresent(Double.self, forKey: .ledGapPercent) ?? defaults.ledGapPercent
        ledRegions = try container.decodeIfPresent([SpectrumLEDRegion].self, forKey: .ledRegions) ?? SpectrumAnalyzerSettings.migratedLEDRegions(
            colors: [darkRedRGB, orangeRedRGB, orangeRGB, yellowRGB],
            relativeSizes: [darkRedRegionPercent, orangeRedRegionPercent, orangeRegionPercent, yellowRegionPercent],
            rowCount: Int(ledSegmentCount.rounded())
        )
        var sanitizedSettings = defaults
        sanitizedSettings.ledSegmentCount = ledSegmentCount
        sanitizedSettings.ledGapPercent = ledGapPercent
        sanitizedSettings.ledRegions = ledRegions
        sanitizedSettings.sanitize()
        ledSegmentCount = sanitizedSettings.ledSegmentCount
        ledGapPercent = sanitizedSettings.ledGapPercent
        ledRegions = sanitizedSettings.ledRegions
    }
}

struct SpectrumSnapshot: Equatable {
    static let empty = SpectrumSnapshot(left: [], right: [], leftPeaks: [], rightPeaks: [])

    let left: [Float]
    let right: [Float]
    let leftPeaks: [Float]
    let rightPeaks: [Float]
}

/// A stable, real-time-safe handoff between the audio graph's taps and the replaceable analyzer.
///
/// The audio graph retains this object for its entire lifetime. Analyzer configuration can therefore
/// replace the analysis worker without reinstalling taps or stopping/recreating any DSP nodes. A tap
/// never waits for a replacement: it drops that analysis buffer if the handoff is momentarily busy.
final class SpectrumAnalyzerInput: @unchecked Sendable {
    private let analyzerPointer: ManagedAtomic<UnsafeRawPointer>
    private let selectedAudioSource: ManagedAtomic<Int>
    private let isRouting = ManagedAtomic<Bool>(false)

    // Accessed only by the serialized control thread. This strong reference owns the object exposed
    // through `analyzerPointer`; `isRouting` prevents it being released during a tap callback.
    private var currentAnalyzer: AudioSpectrumAnalyzer

    init(analyzer: AudioSpectrumAnalyzer, audioSource: SpectrumAudioSource) {
        currentAnalyzer = analyzer
        analyzerPointer = ManagedAtomic(Self.pointer(to: analyzer))
        selectedAudioSource = ManagedAtomic(audioSource.atomicValue)
    }

    /// Called by the audio taps. The callback remains non-blocking when analysis is reconfigured.
    func capture(_ buffer: AVAudioPCMBuffer, from source: SpectrumAudioSource) {
        guard selectedAudioSource.load(ordering: .acquiring) == source.atomicValue,
              isRouting.compareExchange(
                expected: false,
                desired: true,
                ordering: .acquiringAndReleasing
              ).exchanged else { return }
        defer { isRouting.store(false, ordering: .releasing) }

        // Re-check after entering the handoff so a concurrent source switch cannot admit stale data.
        guard selectedAudioSource.load(ordering: .acquiring) == source.atomicValue else { return }
        let analyzer = Unmanaged<AudioSpectrumAnalyzer>
            .fromOpaque(analyzerPointer.load(ordering: .acquiring))
            .takeUnretainedValue()
        analyzer.capture(buffer, from: source)
    }

    /// Atomically changes which observer tap feeds the analyzer; the audio graph is untouched.
    func setAudioSource(_ source: SpectrumAudioSource) {
        let oldValue = selectedAudioSource.exchange(source.atomicValue, ordering: .acquiringAndReleasing)
        guard oldValue != source.atomicValue else { return }
        withRoutingPaused {
            currentAnalyzer.setAudioSource(source)
        }
    }

    /// Swaps only the analysis worker. Audio callbacks either use the old or new worker, never a
    /// partially configured one, and never wait for the control thread.
    func replaceAnalyzer(_ analyzer: AudioSpectrumAnalyzer, audioSource: SpectrumAudioSource) {
        withRoutingPaused {
            let previousAnalyzer = currentAnalyzer
            currentAnalyzer = analyzer
            analyzerPointer.store(Self.pointer(to: analyzer), ordering: .releasing)
            selectedAudioSource.store(audioSource.atomicValue, ordering: .releasing)
            withExtendedLifetime(previousAnalyzer) {}
        }
    }

    func reset() {
        withRoutingPaused {
            currentAnalyzer.reset()
        }
    }

    func resetPeaks() {
        currentAnalyzer.resetPeaks()
    }

    private func withRoutingPaused(_ body: () -> Void) {
        while !isRouting.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged {
            sched_yield()
        }
        defer { isRouting.store(false, ordering: .releasing) }
        body()
    }

    private static func pointer(to analyzer: AudioSpectrumAnalyzer) -> UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(analyzer).toOpaque())
    }
}

private final class SpectrumSnapshotSlot: @unchecked Sendable {
    static let free = 0
    static let writing = 1
    static let ready = 2
    static let reading = 3

    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let state = ManagedAtomic<Int>(free)
    let generation = ManagedAtomic<Int64>(0)
    let sequence = ManagedAtomic<Int64>(0)
    let sampleRateBits = ManagedAtomic<UInt32>(0)

    init(frameCount: Int) {
        left = .allocate(capacity: frameCount)
        right = .allocate(capacity: frameCount)
        left.initialize(repeating: 0, count: frameCount)
        right.initialize(repeating: 0, count: frameCount)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}

/// The selected audio tap is the sole producer: it writes only producer-owned history and free snapshot slots.
final class AudioSpectrumAnalyzer: @unchecked Sendable {
    let fftSize: Int
    let snapshotIntervalFrames: Int
    private let bandCount: Int
    private let minimumDb: Float
    private let maximumDb: Float
    private let queue = DispatchQueue(label: "com.peq.spectrum-fft", qos: .userInitiated)
    private let isEnabled = ManagedAtomic<Bool>(false)
    private let selectedAudioSource: ManagedAtomic<Int>
    private let isCapturing = ManagedAtomic<Bool>(false)
    private let generation = ManagedAtomic<Int64>(0)
    private let bandFallDbPerSecond = AtomicFloat(Float(SpectrumAnalyzerTuning.defaultBandFallDbPerSecond))
    private let peakFallDbPerSecond = AtomicFloat(Float(SpectrumAnalyzerTuning.defaultPeakFallDbPerSecond))
    private let bandSeparation = AtomicFloat(Float(SpectrumAnalyzerTuning.defaultBandSeparation))
    private let peakHoldSeconds = AtomicFloat(Float(SpectrumAnalyzerTuning.defaultPeakHoldSeconds))
    private let historyLeft: UnsafeMutablePointer<Float>
    private let historyRight: UnsafeMutablePointer<Float>
    private let snapshotSlots: [SpectrumSnapshotSlot]
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let window: UnsafeMutablePointer<Float>
    private let windowSum: Float
    private let fftSetup: FFTSetup
    // Producer-only state. `reset()` deliberately does not modify these fields.
    private var producerGeneration: Int64 = 0
    private var historyWriteIndex = 0
    private var historyFrameCount = 0
    private var framesSinceSnapshot = 0
    private var nextSequence: Int64 = 0
    private var leftDisplayed: [Float]
    private var rightDisplayed: [Float]
    private var leftPeaks: [Float]
    private var rightPeaks: [Float]
    private var leftPeakHoldRemaining: [TimeInterval]
    private var rightPeakHoldRemaining: [TimeInterval]
    private var lastPeakUpdate = CACurrentMediaTime()
    private var timer: DispatchSourceTimer?

    private let onSnapshot: (@Sendable (SpectrumSnapshot) -> Void)?

    init(
        settings: SpectrumAnalyzerSettings,
        onSnapshot: (@Sendable (SpectrumSnapshot) -> Void)? = nil
    ) {
        self.onSnapshot = onSnapshot
        fftSize = settings.fftSize
        snapshotIntervalFrames = settings.snapshotHopFrames
        bandCount = settings.bandCount
        minimumDb = Float(settings.minimumDb)
        maximumDb = Float(settings.maximumDb)
        selectedAudioSource = ManagedAtomic(settings.audioSource.atomicValue)
        leftDisplayed = Array(repeating: Float(settings.minimumDb), count: settings.bandCount)
        rightDisplayed = Array(repeating: Float(settings.minimumDb), count: settings.bandCount)
        leftPeaks = Array(repeating: Float(settings.minimumDb), count: settings.bandCount)
        rightPeaks = Array(repeating: Float(settings.minimumDb), count: settings.bandCount)
        leftPeakHoldRemaining = Array(repeating: 0, count: settings.bandCount)
        rightPeakHoldRemaining = Array(repeating: 0, count: settings.bandCount)
        historyLeft = .allocate(capacity: fftSize)
        historyRight = .allocate(capacity: fftSize)
        snapshotSlots = [
            SpectrumSnapshotSlot(frameCount: fftSize), SpectrumSnapshotSlot(frameCount: fftSize),
            SpectrumSnapshotSlot(frameCount: fftSize), SpectrumSnapshotSlot(frameCount: fftSize)
        ]
        real = .allocate(capacity: fftSize)
        imaginary = .allocate(capacity: fftSize)
        magnitudes = .allocate(capacity: fftSize / 2)
        window = .allocate(capacity: fftSize)
        historyLeft.initialize(repeating: 0, count: fftSize)
        historyRight.initialize(repeating: 0, count: fftSize)
        real.initialize(repeating: 0, count: fftSize)
        imaginary.initialize(repeating: 0, count: fftSize)
        magnitudes.initialize(repeating: 0, count: fftSize / 2)
        window.initialize(repeating: 0, count: fftSize)
        vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        var calculatedWindowSum: Float = 0
        vDSP_sve(window, 1, &calculatedWindowSum, vDSP_Length(fftSize))
        windowSum = calculatedWindowSum
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))!

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(settings.refreshIntervalMilliseconds)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.analyzeLatestSamples() }
        timer.resume()
        self.timer = timer
        setDecayRates(bandFallDbPerSecond: settings.bandFallDbPerSecond, peakFallDbPerSecond: settings.peakFallDbPerSecond)
        setBandSeparation(settings.bandSeparation)
        peakHoldSeconds.store(Float(settings.peakHoldSeconds))
    }

    deinit {
        timer?.cancel()
        vDSP_destroy_fftsetup(fftSetup)
        [historyLeft, historyRight, real, imaginary, magnitudes, window].forEach { $0.deallocate() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled.store(enabled, ordering: .releasing)
        if !enabled { reset() }
    }

    func setDecayRates(bandFallDbPerSecond: Double, peakFallDbPerSecond: Double) {
        let range = SpectrumAnalyzerTuning.fallRateRange
        self.bandFallDbPerSecond.store(Float(min(max(bandFallDbPerSecond, range.lowerBound), range.upperBound)))
        self.peakFallDbPerSecond.store(Float(min(max(peakFallDbPerSecond, range.lowerBound), range.upperBound)))
    }

    func setBandSeparation(_ value: Double) {
        let range = SpectrumAnalyzerTuning.bandSeparationRange
        bandSeparation.store(Float(min(max(value, range.lowerBound), range.upperBound)))
    }

    func setPeakHoldSeconds(_ value: Double) { peakHoldSeconds.store(Float(min(max(value, SpectrumAnalyzerSettings.peakHoldRange.lowerBound), SpectrumAnalyzerSettings.peakHoldRange.upperBound))) }

    func setAudioSource(_ source: SpectrumAudioSource) {
        let previous = selectedAudioSource.exchange(source.atomicValue, ordering: .acquiringAndReleasing)
        guard previous != source.atomicValue else { return }

        // The control thread waits for any callback already admitted from the old source. New
        // callbacks cannot enter because the selection changed before this gate is acquired.
        while !isCapturing.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged {
            sched_yield()
        }
        reset()
        isCapturing.store(false, ordering: .releasing)
    }

    /// Called by both audio taps. Only the selected source may enter the producer-owned capture state.
    /// No allocations, dispatching, or FFT work occur here.
    func capture(_ buffer: AVAudioPCMBuffer, from source: SpectrumAudioSource) {
        guard selectedAudioSource.load(ordering: .acquiring) == source.atomicValue,
              isEnabled.load(ordering: .acquiring),
              let channels = buffer.floatChannelData,
              buffer.format.channelCount > 0 else { return }
        guard isCapturing.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged else { return }
        defer { isCapturing.store(false, ordering: .releasing) }

        // Re-check after claiming the producer gate so a source change cannot admit stale samples.
        guard selectedAudioSource.load(ordering: .acquiring) == source.atomicValue else { return }
        let currentGeneration = generation.load(ordering: .acquiring)
        if producerGeneration != currentGeneration {
            producerGeneration = currentGeneration
            historyWriteIndex = 0
            historyFrameCount = 0
            framesSinceSnapshot = 0
        }
        let frameCount = min(Int(buffer.frameLength), fftSize)
        guard frameCount > 0 else { return }
        let left = channels[0]
        let right = channels[min(1, Int(buffer.format.channelCount) - 1)]
        for frame in 0..<frameCount {
            historyLeft[historyWriteIndex] = left[frame]
            historyRight[historyWriteIndex] = right[frame]
            historyWriteIndex = (historyWriteIndex + 1) % fftSize
        }
        historyFrameCount = min(fftSize, historyFrameCount + frameCount)
        framesSinceSnapshot += frameCount
        guard historyFrameCount == fftSize, framesSinceSnapshot >= snapshotIntervalFrames,
              let slot = claimFreeSlot() else { return }
        framesSinceSnapshot = 0
        copyHistory(to: slot)
        slot.generation.store(currentGeneration, ordering: .relaxed)
        slot.sampleRateBits.store(Float(buffer.format.sampleRate).bitPattern, ordering: .relaxed)
        nextSequence &+= 1
        slot.sequence.store(nextSequence, ordering: .relaxed)
        slot.state.store(SpectrumSnapshotSlot.ready, ordering: .releasing)
    }

    func reset() {
        generation.wrappingIncrement(ordering: .acquiringAndReleasing)
        queue.async { [weak self] in
            guard let self else { return }
            let currentGeneration = self.generation.load(ordering: .acquiring)
            for slot in self.snapshotSlots {
                guard slot.state.load(ordering: .acquiring) == SpectrumSnapshotSlot.ready,
                      slot.generation.load(ordering: .relaxed) != currentGeneration else { continue }
                self.releaseReadySlot(slot)
            }
            self.leftPeaks = Array(repeating: self.minimumDb, count: self.bandCount)
            self.rightPeaks = self.leftPeaks
            self.leftPeakHoldRemaining = Array(repeating: 0, count: self.bandCount)
            self.rightPeakHoldRemaining = self.leftPeakHoldRemaining
            self.leftDisplayed = self.leftPeaks
            self.rightDisplayed = self.leftPeaks
            self.lastPeakUpdate = CACurrentMediaTime()
            self.onSnapshot?(SpectrumSnapshot(left: self.leftPeaks, right: self.rightPeaks, leftPeaks: self.leftPeaks, rightPeaks: self.rightPeaks))
        }
    }

    /// Resets only the visual peak markers. Capture history and the audio graph continue unchanged.
    func resetPeaks() {
        queue.async { [weak self] in
            guard let self else { return }
            self.leftPeaks = Array(repeating: self.minimumDb, count: self.bandCount)
            self.rightPeaks = self.leftPeaks
            self.leftPeakHoldRemaining = Array(repeating: 0, count: self.bandCount)
            self.rightPeakHoldRemaining = self.leftPeakHoldRemaining
            self.lastPeakUpdate = CACurrentMediaTime()
            self.onSnapshot?(SpectrumSnapshot(
                left: self.leftDisplayed,
                right: self.rightDisplayed,
                leftPeaks: self.leftPeaks,
                rightPeaks: self.rightPeaks
            ))
        }
    }

    private func analyzeLatestSamples() {
        guard isEnabled.load(ordering: .acquiring) else { return }
        let expectedGeneration = generation.load(ordering: .acquiring)
        var newest: SpectrumSnapshotSlot?
        var newestSequence = Int64.min
        for slot in snapshotSlots where slot.state.load(ordering: .acquiring) == SpectrumSnapshotSlot.ready {
            let slotGeneration = slot.generation.load(ordering: .relaxed)
            if slotGeneration != expectedGeneration {
                releaseReadySlot(slot)
            } else if slot.sequence.load(ordering: .relaxed) > newestSequence {
                newest = slot
                newestSequence = slot.sequence.load(ordering: .relaxed)
            }
        }
        guard let newest else { return }
        for slot in snapshotSlots {
            guard slot !== newest,
                  slot.state.load(ordering: .acquiring) == SpectrumSnapshotSlot.ready,
                  slot.generation.load(ordering: .relaxed) == expectedGeneration else { continue }
            releaseReadySlot(slot)
        }
        guard newest.state.compareExchange(expected: SpectrumSnapshotSlot.ready, desired: SpectrumSnapshotSlot.reading, ordering: .acquiringAndReleasing).exchanged else { return }
        defer { newest.state.store(SpectrumSnapshotSlot.free, ordering: .releasing) }
        guard newest.generation.load(ordering: .relaxed) == expectedGeneration else { return }
        let sampleRate = Float(bitPattern: newest.sampleRateBits.load(ordering: .relaxed))
        guard sampleRate > 0 else { return }
        let snapshot = makeSnapshot(left: newest.left, right: newest.right, sampleRate: sampleRate)
        guard isEnabled.load(ordering: .acquiring), generation.load(ordering: .acquiring) == expectedGeneration else { return }
        onSnapshot?(snapshot)
    }

    private func claimFreeSlot() -> SpectrumSnapshotSlot? {
        for slot in snapshotSlots {
            if slot.state.compareExchange(expected: SpectrumSnapshotSlot.free, desired: SpectrumSnapshotSlot.writing, ordering: .acquiringAndReleasing).exchanged {
                return slot
            }
        }
        return nil
    }

    private func copyHistory(to slot: SpectrumSnapshotSlot) {
        let firstCount = fftSize - historyWriteIndex
        memcpy(slot.left, historyLeft.advanced(by: historyWriteIndex), firstCount * MemoryLayout<Float>.stride)
        memcpy(slot.right, historyRight.advanced(by: historyWriteIndex), firstCount * MemoryLayout<Float>.stride)
        if historyWriteIndex > 0 {
            memcpy(slot.left.advanced(by: firstCount), historyLeft, historyWriteIndex * MemoryLayout<Float>.stride)
            memcpy(slot.right.advanced(by: firstCount), historyRight, historyWriteIndex * MemoryLayout<Float>.stride)
        }
    }

    private func releaseReadySlot(_ slot: SpectrumSnapshotSlot) {
        if slot.state.compareExchange(expected: SpectrumSnapshotSlot.ready, desired: SpectrumSnapshotSlot.reading, ordering: .acquiringAndReleasing).exchanged {
            slot.state.store(SpectrumSnapshotSlot.free, ordering: .releasing)
        }
    }

    private func makeSnapshot(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, sampleRate: Float) -> SpectrumSnapshot {
        let leftBars = makeBars(samples: left, sampleRate: sampleRate)
        let rightBars = makeBars(samples: right, sampleRate: sampleRate)
        let now = CACurrentMediaTime()
        let elapsed = Float(now - lastPeakUpdate)
        lastPeakUpdate = now
        let bandFall = elapsed * bandFallDbPerSecond.load()
        let peakFallRate = peakFallDbPerSecond.load()
        for index in 0..<bandCount {
            leftDisplayed[index] = max(leftBars[index], leftDisplayed[index] - bandFall)
            rightDisplayed[index] = max(rightBars[index], rightDisplayed[index] - bandFall)
            updatePeak(
                candidate: max(leftBars[index], leftDisplayed[index]),
                elapsed: elapsed,
                fallRate: peakFallRate,
                peak: &leftPeaks[index],
                holdRemaining: &leftPeakHoldRemaining[index]
            )
            updatePeak(
                candidate: max(rightBars[index], rightDisplayed[index]),
                elapsed: elapsed,
                fallRate: peakFallRate,
                peak: &rightPeaks[index],
                holdRemaining: &rightPeakHoldRemaining[index]
            )
        }
        return SpectrumSnapshot(left: leftDisplayed, right: rightDisplayed, leftPeaks: leftPeaks, rightPeaks: rightPeaks)
    }

    private func updatePeak(
        candidate: Float,
        elapsed: Float,
        fallRate: Float,
        peak: inout Float,
        holdRemaining: inout TimeInterval
    ) {
        if candidate >= peak {
            peak = candidate
            holdRemaining = TimeInterval(peakHoldSeconds.load())
            return
        }

        let heldDuration = min(TimeInterval(elapsed), holdRemaining)
        holdRemaining -= heldDuration
        let decayDuration = max(0, elapsed - Float(heldDuration))
        peak = max(candidate, peak - (fallRate * decayDuration))
    }

    private func makeBars(samples: UnsafeMutablePointer<Float>, sampleRate: Float) -> [Float] {
        vDSP_vmul(samples, 1, window, 1, real, 1, vDSP_Length(fftSize))
        vDSP_vclr(imaginary, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        vDSP_fft_zip(fftSetup, &split, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, magnitudes, 1, vDSP_Length(fftSize / 2))
        var amplitudes = Array(repeating: Float.zero, count: bandCount)
        let nyquist = sampleRate / 2
        guard nyquist > 20 else { return Array(repeating: minimumDb, count: bandCount) }
        let amplitudeScale = 2 / windowSum

        for bar in amplitudes.indices {
            let centerFrequency = SpectrumAnalyzerTuning.centerFrequency(forBand: bar, bandCount: amplitudes.count)
            guard centerFrequency <= nyquist else { continue }
            let exactBin = centerFrequency * Float(fftSize) / sampleRate
            let lowerBin = max(1, min((fftSize / 2) - 1, Int(floor(exactBin))))
            let upperBin = min((fftSize / 2) - 1, lowerBin + 1)
            let fraction = min(1, max(0, exactBin - Float(lowerBin)))
            let lowerMagnitude = sqrtf(magnitudes[lowerBin])
            let upperMagnitude = sqrtf(magnitudes[upperBin])
            amplitudes[bar] = (lowerMagnitude + ((upperMagnitude - lowerMagnitude) * fraction)) * amplitudeScale
        }
        let separatedAmplitudes = applyBandSeparation(to: amplitudes)
        return separatedAmplitudes.map {
            min(maximumDb, max(minimumDb, 20 * log10f(max($0, 0.000_000_03))))
        }
    }

    /// A bounded linear-amplitude neighbor subtraction reduces bleed without boosting measured amplitudes.
    private func applyBandSeparation(to amplitudes: [Float]) -> [Float] {
        let amount = bandSeparation.load()
        guard amount > 0, amplitudes.count > 1 else { return amplitudes }
        var separated = amplitudes
        for index in amplitudes.indices {
            let neighborAverage: Float
            if index == 0 {
                neighborAverage = amplitudes[1]
            } else if index == amplitudes.index(before: amplitudes.endIndex) {
                neighborAverage = amplitudes[index - 1]
            } else {
                neighborAverage = (amplitudes[index - 1] + amplitudes[index + 1]) * 0.5
            }
            let retentionFloor = amplitudes[index] * (1 - amount)
            let attenuated = amplitudes[index] - (amount * neighborAverage)
            separated[index] = min(amplitudes[index], max(retentionFloor, max(0, attenuated)))
        }
        return separated
    }
}

struct SpectrumAnalyzerView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var nowPlaying = AppleMusicNowPlayingProvider()
    @State private var chromeOpacity = 1.0
    @State private var hideChromeWorkItem: DispatchWorkItem?
    @State private var trackInfoDriftWorkItem: DispatchWorkItem?
    @State private var trackInfoOffset = CGSize.zero
    @State private var cursorIsHidden = false
    @State private var lastTrackIdentity: AppleMusicTrackInfo.Identity?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                if appState.spectrumSettings.layoutMode == .fullSpectrum {
                    spectrumContent
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack(spacing: 0) {
                        Color.clear
                            .overlay {
                                AppleMusicTrackInfoView(state: nowPlaying.state)
                                    .offset(trackInfoOffset)
                            }
                            .frame(width: geometry.size.width, height: geometry.size.height * 0.4)
                            .clipped()

                        spectrumContent
                            .frame(width: geometry.size.width, height: geometry.size.height * 0.6)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }

            SpectrumActivityMonitor(onActivity: recordActivity)
                .allowsHitTesting(false)
        }
        .frame(minWidth: 900, minHeight: 600)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { keyPress in
            recordActivity()
            guard keyPress.characters.lowercased() == "o" else { return .ignored }
            appState.showSpectrumSettings()
            return .handled
        }
        .onAppear {
            updateNowPlayingPolling()
            recordActivity()
        }
        .onChange(of: appState.spectrumSettings.layoutMode) {
            updateNowPlayingPolling()
            recordActivity()
        }
        .onChange(of: appState.isSpectrumPresented) {
            updateNowPlayingPolling()
            if appState.isSpectrumPresented {
                recordActivity()
            } else {
                revealCursor()
            }
        }
        .onChange(of: nowPlaying.state) {
            resetSpectrumPeaksForNewTrack()
        }
        .onDisappear {
            hideChromeWorkItem?.cancel()
            hideChromeWorkItem = nil
            trackInfoDriftWorkItem?.cancel()
            trackInfoDriftWorkItem = nil
            nowPlaying.stop()
            revealCursor()
        }
    }

    private var spectrumContent: some View {
        ZStack {
            SpectrumMetalView(
                snapshot: appState.spectrum,
                settings: appState.spectrumSettings,
                chromeOpacity: Float(appState.spectrumSettings.hidePlotLabelsWhenIdle ? chromeOpacity : 1)
            ) { fps in
                appState.reportSpectrumRenderFPS(fps)
            }
            SpectrumPlotLabels(
                minimumDb: Float(appState.spectrumSettings.minimumDb),
                maximumDb: Float(appState.spectrumSettings.maximumDb),
                bandCount: appState.spectrumSettings.bandCount
            )
                .opacity(appState.spectrumSettings.hidePlotLabelsWhenIdle ? chromeOpacity : 1)
                .allowsHitTesting(false)
        }
        .contextMenu {
            Button("Spectrum Options…") {
                recordActivity()
                appState.showSpectrumSettings()
            }
        }
    }

    private func recordActivity() {
        revealCursor()
        hideChromeWorkItem?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            chromeOpacity = 1
        }

        let workItem = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.8)) {
                chromeOpacity = 0
            }
            guard !cursorIsHidden else { return }
            NSCursor.setHiddenUntilMouseMoves(true)
            cursorIsHidden = true
        }
        hideChromeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    private func revealCursor() {
        guard cursorIsHidden else { return }
        NSCursor.unhide()
        cursorIsHidden = false
    }

    private func updateNowPlayingPolling() {
        if appState.isSpectrumPresented,
           appState.spectrumSettings.layoutMode == .trackInfoAndSpectrum {
            nowPlaying.start()
            ensureTrackInfoDriftScheduled()
        } else {
            nowPlaying.stop()
            trackInfoDriftWorkItem?.cancel()
            trackInfoDriftWorkItem = nil
            trackInfoOffset = .zero
        }
    }

    private func resetSpectrumPeaksForNewTrack() {
        guard case let .playing(track) = nowPlaying.state else {
            lastTrackIdentity = nil
            return
        }
        guard track.identity != lastTrackIdentity else { return }
        lastTrackIdentity = track.identity
        appState.resetSpectrumPeaks()
    }

    private func ensureTrackInfoDriftScheduled() {
        guard trackInfoDriftWorkItem == nil,
              appState.isSpectrumPresented,
              appState.spectrumSettings.layoutMode == .trackInfoAndSpectrum else { return }

        let workItem = DispatchWorkItem {
            trackInfoDriftWorkItem = nil
            guard appState.isSpectrumPresented,
                  appState.spectrumSettings.layoutMode == .trackInfoAndSpectrum else { return }
            let offsets = [-2.0, -1.0, 1.0, 2.0]
            withAnimation(.easeInOut(duration: 0.8)) {
                trackInfoOffset = CGSize(
                    width: offsets.randomElement() ?? 1,
                    height: offsets.randomElement() ?? -1
                )
            }
            ensureTrackInfoDriftScheduled()
        }
        trackInfoDriftWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 30...60), execute: workItem)
    }
}

private struct SpectrumActivityMonitor: NSViewRepresentable {
    let onActivity: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onActivity: onActivity)
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        context.coordinator.onActivity = onActivity
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class MonitorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.monitor(window: window)
        }
    }

    final class Coordinator {
        var onActivity: () -> Void
        private weak var monitoredWindow: NSWindow?
        private var eventMonitor: Any?

        init(onActivity: @escaping () -> Void) {
            self.onActivity = onActivity
        }

        deinit {
            stopMonitoring()
        }

        func monitor(window: NSWindow?) {
            monitoredWindow = window
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .mouseMoved,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .scrollWheel,
                .keyDown
            ]) { [weak self] event in
                guard let self, event.window === monitoredWindow else { return event }
                onActivity()
                return event
            }
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            monitoredWindow = nil
        }
    }
}

private struct SpectrumPlotLabels: View {
    let minimumDb: Float
    let maximumDb: Float
    let bandCount: Int

    var body: some View {
        GeometryReader { geometry in
            let plot = SpectrumPlotLayout.plotRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(dbTicks, id: \.self) { tick in
                    Text("\(Int(tick))")
                        .font(.system(size: 9, weight: .light, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                        .position(x: plot.minX - 16, y: yPosition(tick, in: plot))

                    Text("\(Int(tick))")
                        .font(.system(size: 9, weight: .light, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                        .position(x: plot.maxX + 16, y: yPosition(tick, in: plot))
                }

                ForEach(Array(stride(from: 0, to: bandCount, by: 2)), id: \.self) { band in
                    Text(frequencyLabel(forBand: band))
                        .font(.system(size: labelFontSize(for: plot), weight: .light, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .position(x: xPosition(forBand: band, in: plot), y: plot.maxY + 12)
                }
            }
        }
    }

    private func yPosition(_ db: Float, in plot: CGRect) -> CGFloat {
        let fraction = CGFloat((db - minimumDb) / (maximumDb - minimumDb))
        return plot.maxY - (fraction * plot.height)
    }

    private func xPosition(forBand band: Int, in plot: CGRect) -> CGFloat {
        plot.minX + ((CGFloat(band) + 0.5) / CGFloat(max(1, bandCount))) * plot.width
    }

    private func labelFontSize(for plot: CGRect) -> CGFloat {
        let widthPerLabel = (plot.width / CGFloat(max(1, bandCount))) * 2
        return min(9, max(4.5, widthPerLabel * 0.32))
    }

    private func frequencyLabel(forBand band: Int) -> String {
        let frequency = SpectrumAnalyzerTuning.centerFrequency(forBand: band, bandCount: bandCount)
        if frequency < 1_000 {
            return "\(Int(frequency.rounded()))"
        }
        let kilohertz = frequency / 1_000
        return kilohertz >= 10 ? String(format: "%.0fk", kilohertz) : String(format: "%.1fk", kilohertz)
    }

    private var dbTicks: [Float] {
        SpectrumAnalyzerTuning.dbTicks(minimum: minimumDb, maximum: maximumDb)
    }
}
