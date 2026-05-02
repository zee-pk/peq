import AVFoundation
import Darwin

final class AudioRingBuffer {
    private let channelCount = 2
    private let capacityFrames: Int
    private let targetFillFrames: Int
    private let maximumBufferedFrames: Int
    private let buffers: [UnsafeMutablePointer<Float>]

    private let writeCursor = AtomicInt64(0)
    private let readCursor = AtomicInt64(0)
    private let writtenFrames = AtomicInt64(0)
    private let renderedFrames = AtomicInt64(0)
    private let underrunCount = AtomicInt64(0)
    private let droppedFrameCount = AtomicInt64(0)
    private let trimmedFrameCount = AtomicInt64(0)
    private var isPrimed = false

    init(capacityFrames: Int, targetFillFrames: Int) {
        let resolvedCapacity = max(capacityFrames, 4096)
        let resolvedTargetFill = min(max(targetFillFrames, 256), resolvedCapacity / 4)

        self.capacityFrames = resolvedCapacity
        self.targetFillFrames = resolvedTargetFill
        self.maximumBufferedFrames = min(resolvedCapacity - 1, resolvedTargetFill * 4)
        self.buffers = (0..<channelCount).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: resolvedCapacity)
            pointer.initialize(repeating: 0, count: resolvedCapacity)
            return pointer
        }
    }

    deinit {
        for buffer in buffers {
            buffer.deinitialize(count: capacityFrames)
            buffer.deallocate()
        }
    }

    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }

        let framesToWrite = writableFrameCount(for: frameCount)
        guard framesToWrite > 0 else {
            droppedFrameCount.add(Int64(frameCount))
            return
        }

        let sourceStartFrame = frameCount - framesToWrite
        let writeStart = writeCursor.load()

        writeChannel(source: left.advanced(by: sourceStartFrame), channel: 0, frameCount: framesToWrite, writeStart: writeStart)
        writeChannel(source: right.advanced(by: sourceStartFrame), channel: 1, frameCount: framesToWrite, writeStart: writeStart)

        writeCursor.store(writeStart + Int64(framesToWrite))
        writtenFrames.add(Int64(framesToWrite))

        if framesToWrite < frameCount {
            droppedFrameCount.add(Int64(frameCount - framesToWrite))
        }
    }

    func read(into outputData: UnsafeMutablePointer<AudioBufferList>, frameCount: AVAudioFrameCount) -> Bool {
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        let requestedFrames = Int(frameCount)

        zero(outputBuffers)
        guard requestedFrames > 0 else { return false }

        let write = writeCursor.load()
        var read = readCursor.load()
        var available = boundedAvailableFrames(write: write, read: read)

        guard isReadyToRender(availableFrames: available, requestedFrames: requestedFrames) else {
            underrunCount.add(1)
            return false
        }

        if available > maximumBufferedFrames {
            let targetRead = write - Int64(targetFillFrames)
            let trimmedFrames = max(Int64(0), targetRead - read)
            readCursor.store(targetRead)
            trimmedFrameCount.add(trimmedFrames)
            read = targetRead
            available = targetFillFrames
        }

        guard available >= requestedFrames else {
            isPrimed = false
            underrunCount.add(1)
            return false
        }

        if outputBuffers.count >= 2 {
            readNonInterleaved(into: outputBuffers, frameCount: requestedFrames, readStart: read)
        } else if let output = outputBuffers.first {
            readInterleaved(into: output, frameCount: requestedFrames, readStart: read)
        }

        readCursor.store(read + Int64(requestedFrames))
        renderedFrames.add(Int64(requestedFrames))
        return true
    }

    func diagnosticsSnapshot() -> AudioRingBufferDiagnostics {
        let write = writeCursor.load()
        let read = readCursor.load()

        return AudioRingBufferDiagnostics(
            availableFrames: boundedAvailableFrames(write: write, read: read),
            writtenFrames: writtenFrames.load(),
            renderedFrames: renderedFrames.load(),
            underruns: underrunCount.load(),
            droppedFrames: droppedFrameCount.load(),
            trimmedFrames: trimmedFrameCount.load()
        )
    }

    func prefillSilence(frameCount: Int) {
        let frames = min(max(frameCount, 0), capacityFrames / 2)
        guard frames > 0 else { return }

        let writeStart = writeCursor.load()
        for frame in 0..<frames {
            let targetIndex = bufferIndex(writeStart + Int64(frame))
            buffers[0][targetIndex] = 0
            buffers[1][targetIndex] = 0
        }

        writeCursor.store(writeStart + Int64(frames))
    }

    private func writeChannel(
        source: UnsafePointer<Float>,
        channel: Int,
        frameCount: Int,
        writeStart: Int64
    ) {
        for frame in 0..<frameCount {
            buffers[channel][bufferIndex(writeStart + Int64(frame))] = source[frame]
        }
    }

    private func readNonInterleaved(
        into outputBuffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        readStart: Int64
    ) {
        for channel in 0..<min(channelCount, outputBuffers.count) {
            guard let data = outputBuffers[channel].mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)

            for frame in 0..<frameCount {
                samples[frame] = buffers[channel][bufferIndex(readStart + Int64(frame))]
            }
        }
    }

    private func readInterleaved(
        into outputBuffer: AudioBuffer,
        frameCount: Int,
        readStart: Int64
    ) {
        guard let data = outputBuffer.mData else { return }

        let samples = data.assumingMemoryBound(to: Float.self)
        let outputChannels = max(1, min(Int(outputBuffer.mNumberChannels), channelCount))

        for frame in 0..<frameCount {
            for channel in 0..<outputChannels {
                samples[(frame * outputChannels) + channel] = buffers[channel][bufferIndex(readStart + Int64(frame))]
            }
        }
    }

    private func writableFrameCount(for inputFrameCount: Int) -> Int {
        let write = writeCursor.load()
        let read = readCursor.load()
        let available = boundedAvailableFrames(write: write, read: read)
        let freeFrames = max(0, capacityFrames - available - 1)

        return min(inputFrameCount, freeFrames)
    }

    private func isReadyToRender(availableFrames: Int, requestedFrames: Int) -> Bool {
        if !isPrimed {
            guard availableFrames >= max(targetFillFrames, requestedFrames) else {
                return false
            }

            isPrimed = true
        }

        return availableFrames >= requestedFrames
    }

    private func zero(_ outputBuffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in outputBuffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    private func boundedAvailableFrames(write: Int64, read: Int64) -> Int {
        let available = max(Int64(0), write - read)
        return min(Int(available), capacityFrames - 1)
    }

    private func bufferIndex(_ cursor: Int64) -> Int {
        Int(cursor % Int64(capacityFrames))
    }
}

struct AudioRingBufferDiagnostics {
    let availableFrames: Int
    let writtenFrames: Int64
    let renderedFrames: Int64
    let underruns: Int64
    let droppedFrames: Int64
    let trimmedFrames: Int64
}
