import Foundation

struct AudioHealthSnapshot: Equatable {
    var bufferFillFrames: Int
    var writtenFrames: Int64
    var renderedFrames: Int64
    var underruns: Int64
    var droppedFrames: Int64
    var trimmedFrames: Int64
    var rebuildCount: Int64
    var tapSampleRate: Double
    var tapBitDepth: Int
    var outputSampleRate: Double
    var outputBitDepth: Int
    var capturedPeak: Float
    var outputPeak: Float
    var effectivePreampDb: Double

    static let empty = AudioHealthSnapshot(
        bufferFillFrames: 0,
        writtenFrames: 0,
        renderedFrames: 0,
        underruns: 0,
        droppedFrames: 0,
        trimmedFrames: 0,
        rebuildCount: 0,
        tapSampleRate: 0,
        tapBitDepth: 0,
        outputSampleRate: 0,
        outputBitDepth: 0,
        capturedPeak: 0,
        outputPeak: 0,
        effectivePreampDb: 0
    )
}

final class AudioHealthStore {
    private let bufferFillFrames = AtomicInt64(0)
    private let writtenFrames = AtomicInt64(0)
    private let renderedFrames = AtomicInt64(0)
    private let underruns = AtomicInt64(0)
    private let droppedFrames = AtomicInt64(0)
    private let trimmedFrames = AtomicInt64(0)
    private let rebuildCount = AtomicInt64(0)
    private let tapSampleRate = AtomicFloat(0)
    private let tapBitDepth = AtomicInt64(0)
    private let outputSampleRate = AtomicFloat(0)
    private let outputBitDepth = AtomicInt64(0)
    private let capturedPeak = AtomicFloat(0)
    private let outputPeak = AtomicFloat(0)
    private let effectivePreampDb = AtomicFloat(0)

    func updateRingDiagnostics(_ diagnostics: AudioRingBufferDiagnostics) {
        bufferFillFrames.store(Int64(diagnostics.availableFrames))
        writtenFrames.store(diagnostics.writtenFrames)
        renderedFrames.store(diagnostics.renderedFrames)
        underruns.store(diagnostics.underruns)
        droppedFrames.store(diagnostics.droppedFrames)
        trimmedFrames.store(diagnostics.trimmedFrames)
    }

    func setTapFormat(sampleRate: Double, bitDepth: Int) {
        tapSampleRate.store(Float(sampleRate))
        tapBitDepth.store(Int64(bitDepth))
    }

    func setOutputFormat(sampleRate: Double, bitDepth: Int) {
        outputSampleRate.store(Float(sampleRate))
        outputBitDepth.store(Int64(bitDepth))
    }

    func incrementRebuildCount() {
        rebuildCount.add(1)
    }

    func storeCapturedPeak(_ peak: Float) {
        capturedPeak.storeMax(peak)
    }

    func storeOutputPeak(_ peak: Float) {
        outputPeak.store(peak)
    }

    func setEffectivePreampDb(_ value: Double) {
        effectivePreampDb.store(Float(value))
    }

    func snapshot() -> AudioHealthSnapshot {
        AudioHealthSnapshot(
            bufferFillFrames: Int(bufferFillFrames.load()),
            writtenFrames: writtenFrames.load(),
            renderedFrames: renderedFrames.load(),
            underruns: underruns.load(),
            droppedFrames: droppedFrames.load(),
            trimmedFrames: trimmedFrames.load(),
            rebuildCount: rebuildCount.load(),
            tapSampleRate: Double(tapSampleRate.load()),
            tapBitDepth: Int(tapBitDepth.load()),
            outputSampleRate: Double(outputSampleRate.load()),
            outputBitDepth: Int(outputBitDepth.load()),
            capturedPeak: capturedPeak.load(),
            outputPeak: outputPeak.load(),
            effectivePreampDb: Double(effectivePreampDb.load())
        )
    }
}
