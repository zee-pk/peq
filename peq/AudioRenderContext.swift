import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

final class AudioRenderContext {
    let healthStore: AudioHealthStore

    private let ringBuffer: AudioRingBuffer
    private let sampleReader: InputSampleReader
    private let fadeGain = AtomicFloat(1)

    init(
        tapFormat: AudioStreamBasicDescription,
        maxFrameCount: Int,
        healthStore: AudioHealthStore
    ) throws {
        let reader = try InputSampleReader(format: tapFormat, maxFrameCount: maxFrameCount)
        let targetFillFrames = Int(reader.sampleRate * 0.012)

        self.healthStore = healthStore
        self.sampleReader = reader
        self.ringBuffer = AudioRingBuffer(
            capacityFrames: Int(reader.sampleRate * 2),
            targetFillFrames: targetFillFrames
        )

        ringBuffer.prefillSilence(frameCount: targetFillFrames)
        healthStore.setTapFormat(sampleRate: reader.sampleRate, bitDepth: reader.bitDepth)
    }

    func writeInput(_ inputData: UnsafePointer<AudioBufferList>) {
        sampleReader.writeStereo(from: inputData, to: ringBuffer, healthStore: healthStore)
    }

    func renderOutput(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        frameCount: AVAudioFrameCount,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let hasAudio = ringBuffer.read(into: outputData, frameCount: frameCount)
        let diagnostics = ringBuffer.diagnosticsSnapshot()
        healthStore.updateRingDiagnostics(diagnostics)

        if hasAudio {
            applyFade(to: outputData, frameCount: Int(frameCount))
        }

        isSilence.pointee = ObjCBool(!hasAudio)
        return noErr
    }

    func setFadeGain(_ gain: Float) {
        fadeGain.store(min(1, max(0, gain)))
    }

    func currentFadeGain() -> Float {
        fadeGain.load()
    }

    private func applyFade(to outputData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let gain = fadeGain.load()
        guard gain < 0.999 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size

            for index in 0..<min(sampleCount, frameCount * max(1, Int(buffer.mNumberChannels))) {
                samples[index] *= gain
            }
        }
    }
}
