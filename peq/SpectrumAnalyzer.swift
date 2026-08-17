import Accelerate
import AVFoundation
import Atomics
import Darwin
import SwiftUI

enum SpectrumAnalyzerTuning {
    // 4,096 samples is ~85 ms at 48 kHz: materially less latency while retaining useful bass resolution.
    static let fftSize = 4_096
    static let snapshotHopFrames = 256
    static let refreshInterval = DispatchTimeInterval.milliseconds(8)
    static let defaultBandFallDbPerSecond = 45.0
    static let defaultPeakFallDbPerSecond = 18.0
    static let fallRateRange: ClosedRange<Double> = 1...240
    static let defaultBandSeparation = 0.35
    static let bandSeparationRange: ClosedRange<Double> = 0...0.8
}

struct SpectrumSnapshot: Equatable {
    static let barCount = 72
    static let floorDb: Float = -90
    static let ceilingDb: Float = 0
    static let empty = SpectrumSnapshot(left: Array(repeating: floorDb, count: barCount), right: Array(repeating: floorDb, count: barCount), leftPeaks: Array(repeating: floorDb, count: barCount), rightPeaks: Array(repeating: floorDb, count: barCount))

    let left: [Float]
    let right: [Float]
    let leftPeaks: [Float]
    let rightPeaks: [Float]
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

/// The mixer tap is an SPSC producer: it writes only producer-owned history and free snapshot slots.
final class AudioSpectrumAnalyzer: @unchecked Sendable {
    private let fftSize = SpectrumAnalyzerTuning.fftSize
    private let snapshotIntervalFrames = SpectrumAnalyzerTuning.snapshotHopFrames
    private let queue = DispatchQueue(label: "com.peq.spectrum-fft", qos: .userInitiated)
    private let isEnabled = ManagedAtomic<Bool>(false)
    private let generation = ManagedAtomic<Int64>(0)
    private let bandFallDbPerSecond = AtomicFloat(Float(SpectrumAnalyzerTuning.defaultBandFallDbPerSecond))
    private let peakFallDbPerSecond = AtomicFloat(Float(SpectrumAnalyzerTuning.defaultPeakFallDbPerSecond))
    private let bandSeparation = AtomicFloat(Float(SpectrumAnalyzerTuning.defaultBandSeparation))
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
    private var leftDisplayed = Array(repeating: SpectrumSnapshot.floorDb, count: SpectrumSnapshot.barCount)
    private var rightDisplayed = Array(repeating: SpectrumSnapshot.floorDb, count: SpectrumSnapshot.barCount)
    private var leftPeaks = Array(repeating: SpectrumSnapshot.floorDb, count: SpectrumSnapshot.barCount)
    private var rightPeaks = Array(repeating: SpectrumSnapshot.floorDb, count: SpectrumSnapshot.barCount)
    private var lastPeakUpdate = CACurrentMediaTime()
    private var timer: DispatchSourceTimer?

    var onSnapshot: (@Sendable (SpectrumSnapshot) -> Void)?

    init() {
        historyLeft = .allocate(capacity: fftSize)
        historyRight = .allocate(capacity: fftSize)
        snapshotSlots = [
            SpectrumSnapshotSlot(frameCount: SpectrumAnalyzerTuning.fftSize),
            SpectrumSnapshotSlot(frameCount: SpectrumAnalyzerTuning.fftSize),
            SpectrumSnapshotSlot(frameCount: SpectrumAnalyzerTuning.fftSize),
            SpectrumSnapshotSlot(frameCount: SpectrumAnalyzerTuning.fftSize)
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
        timer.schedule(deadline: .now() + SpectrumAnalyzerTuning.refreshInterval, repeating: SpectrumAnalyzerTuning.refreshInterval)
        timer.setEventHandler { [weak self] in self?.analyzeLatestSamples() }
        timer.resume()
        self.timer = timer
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

    /// Called by the post-EQ mixer tap. No allocations, dispatching, or FFT work occur here.
    func capture(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled.load(ordering: .acquiring),
              let channels = buffer.floatChannelData,
              buffer.format.channelCount > 0 else { return }
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
            self.leftPeaks = Array(repeating: SpectrumSnapshot.floorDb, count: SpectrumSnapshot.barCount)
            self.rightPeaks = self.leftPeaks
            self.leftDisplayed = self.leftPeaks
            self.rightDisplayed = self.leftPeaks
            self.lastPeakUpdate = CACurrentMediaTime()
            self.onSnapshot?(.empty)
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
        let peakFall = elapsed * peakFallDbPerSecond.load()
        for index in 0..<SpectrumSnapshot.barCount {
            leftDisplayed[index] = max(leftBars[index], leftDisplayed[index] - bandFall)
            rightDisplayed[index] = max(rightBars[index], rightDisplayed[index] - bandFall)
            leftPeaks[index] = max(leftBars[index], leftDisplayed[index], leftPeaks[index] - peakFall)
            rightPeaks[index] = max(rightBars[index], rightDisplayed[index], rightPeaks[index] - peakFall)
        }
        return SpectrumSnapshot(left: leftDisplayed, right: rightDisplayed, leftPeaks: leftPeaks, rightPeaks: rightPeaks)
    }

    private func makeBars(samples: UnsafeMutablePointer<Float>, sampleRate: Float) -> [Float] {
        vDSP_vmul(samples, 1, window, 1, real, 1, vDSP_Length(fftSize))
        vDSP_vclr(imaginary, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        vDSP_fft_zip(fftSetup, &split, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, magnitudes, 1, vDSP_Length(fftSize / 2))
        var amplitudes = Array(repeating: Float.zero, count: SpectrumSnapshot.barCount)
        let nyquist = sampleRate / 2
        guard nyquist > 20 else { return Array(repeating: SpectrumSnapshot.floorDb, count: SpectrumSnapshot.barCount) }
        let amplitudeScale = 2 / windowSum

        for bar in amplitudes.indices {
            let centerFrequency = 20 * powf(1_000, (Float(bar) + 0.5) / Float(amplitudes.count))
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
            min(SpectrumSnapshot.ceilingDb, max(SpectrumSnapshot.floorDb, 20 * log10f(max($0, 0.000_000_03))))
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

    private let dbTicks: [Float] = [0, -12, -24, -36, -48, -60, -72, -84]
    private let frequencyTicks: [(Float, String)] = [(20, "20"), (100, "100"), (1_000, "1k"), (5_000, "5k"), (10_000, "10k"), (20_000, "20k")]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("POST-EQ SPECTRUM")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(appState.isProcessing ? "Output mixer · 20 Hz – 20 kHz · 4,096-point FFT" : "Enable EQ to analyze output")
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.55))
                        Text(String(
                            format: "Analyzer %.0f · Delivery %.0f · Metal %.0f fps",
                            appState.spectrumPerformance.analyzerFPS,
                            appState.spectrumPerformance.deliveryFPS,
                            appState.spectrumPerformance.renderFPS
                        ))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)

                ZStack {
                    SpectrumMetalView(snapshot: appState.spectrum) { fps in
                        appState.reportSpectrumRenderFPS(fps)
                    }
                    SpectrumPlotLabels(dbTicks: dbTicks, frequencyTicks: frequencyTicks)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.bottom, 28)

            Button {
                appState.toggleSpectrumFullScreen()
            } label: {
                Label(
                    appState.isSpectrumFullScreen ? "Exit Full Screen" : "Enter Full Screen",
                    systemImage: appState.isSpectrumFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                )
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.18))
            .foregroundStyle(.white)
            .padding(24)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct SpectrumPlotLabels: View {
    let dbTicks: [Float]
    let frequencyTicks: [(Float, String)]

    var body: some View {
        GeometryReader { geometry in
            let plots = SpectrumPlotLayout.plotRects(in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(plots.enumerated()), id: \.offset) { channel, plot in
                    Text(channel == 0 ? "LEFT" : "RIGHT")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)
                        .position(x: 48, y: plot.minY - 12)

                    ForEach(dbTicks, id: \.self) { tick in
                        Text("\(Int(tick))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .position(x: 48, y: yPosition(tick, in: plot))
                    }

                    ForEach(Array(frequencyTicks.enumerated()), id: \.offset) { _, frequencyTick in
                        Text(frequencyTick.1)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .position(x: xPosition(frequencyTick.0, in: plot), y: plot.maxY + 12)
                    }
                }
            }
        }
    }

    private func yPosition(_ db: Float, in plot: CGRect) -> CGFloat {
        let fraction = CGFloat((db - SpectrumSnapshot.floorDb) / (SpectrumSnapshot.ceilingDb - SpectrumSnapshot.floorDb))
        return plot.maxY - (fraction * plot.height)
    }

    private func xPosition(_ frequency: Float, in plot: CGRect) -> CGFloat {
        let fraction = log10f(frequency / 20) / 3
        return plot.minX + CGFloat(fraction) * plot.width
    }
}
