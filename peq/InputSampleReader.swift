import AudioToolbox
import CoreAudio
import Foundation

final class InputSampleReader {
    let sampleRate: Double
    let channelCount: Int
    let bitDepth: Int

    private let sampleFormat: InputSampleFormat
    private let isNonInterleaved: Bool
    private let bytesPerSample: Int
    private let bytesPerFrame: Int
    private let isBigEndian: Bool
    private let scratchLeft: UnsafeMutablePointer<Float>
    private let scratchRight: UnsafeMutablePointer<Float>
    private let scratchCapacity: Int

    init(format: AudioStreamBasicDescription, maxFrameCount: Int) throws {
        self.sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        self.channelCount = max(1, Int(format.mChannelsPerFrame))
        self.bitDepth = Int(format.mBitsPerChannel)
        self.sampleFormat = InputSampleFormat(format: format)
        self.isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        self.bytesPerSample = max(1, Int((format.mBitsPerChannel + 7) / 8))
        self.bytesPerFrame = max(Int(format.mBytesPerFrame), self.bytesPerSample)
        self.isBigEndian = (format.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        self.scratchCapacity = max(maxFrameCount, 512)

        guard sampleFormat != .unsupported else {
            throw AudioRuntimeError.engine("Unsupported tap audio format")
        }

        scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        scratchLeft.initialize(repeating: 0, count: scratchCapacity)
        scratchRight.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        scratchLeft.deinitialize(count: scratchCapacity)
        scratchRight.deinitialize(count: scratchCapacity)
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    func writeStereo(from audioBufferList: UnsafePointer<AudioBufferList>, to ringBuffer: AudioRingBuffer, healthStore: AudioHealthStore) {
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        guard !inputBuffers.isEmpty else { return }

        let inputFrameCount = min(frameCount(in: inputBuffers), scratchCapacity)
        guard inputFrameCount > 0 else { return }

        if isNonInterleaved {
            copyNonInterleaved(inputBuffers, frameCount: inputFrameCount, healthStore: healthStore)
        } else {
            copyInterleaved(inputBuffers[0], frameCount: inputFrameCount, healthStore: healthStore)
        }

        ringBuffer.write(left: scratchLeft, right: scratchRight, frameCount: inputFrameCount)
    }

    private func frameCount(in inputBuffers: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let firstBuffer = inputBuffers.first else { return 0 }

        if isNonInterleaved {
            return Int(firstBuffer.mDataByteSize) / bytesPerFrame
        }

        let sourceChannels = max(1, Int(firstBuffer.mNumberChannels))
        let inputBytesPerFrame = max(bytesPerFrame, sourceChannels * bytesPerSample)
        return Int(firstBuffer.mDataByteSize) / inputBytesPerFrame
    }

    private func copyNonInterleaved(
        _ inputBuffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        healthStore: AudioHealthStore
    ) {
        for frame in 0..<frameCount {
            let left = readNonInterleavedSample(inputBuffers, channel: 0, frame: frame)
            let right = readNonInterleavedSample(inputBuffers, channel: 1, frame: frame)
            scratchLeft[frame] = left
            scratchRight[frame] = right
            healthStore.storeCapturedPeak(max(abs(left), abs(right)))
        }
    }

    private func copyInterleaved(
        _ inputBuffer: AudioBuffer,
        frameCount: Int,
        healthStore: AudioHealthStore
    ) {
        guard let data = inputBuffer.mData else { return }

        let sourceChannels = max(1, min(Int(inputBuffer.mNumberChannels), 2))
        let bytesPerInputFrame = max(bytesPerFrame, sourceChannels * bytesPerSample)

        for frame in 0..<frameCount {
            let left = readSample(data: data, frame: frame, channel: 0, bytesPerInputFrame: bytesPerInputFrame)
            let right = readSample(data: data, frame: frame, channel: min(1, sourceChannels - 1), bytesPerInputFrame: bytesPerInputFrame)
            scratchLeft[frame] = left
            scratchRight[frame] = right
            healthStore.storeCapturedPeak(max(abs(left), abs(right)))
        }
    }

    private func readNonInterleavedSample(
        _ inputBuffers: UnsafeMutableAudioBufferListPointer,
        channel: Int,
        frame: Int
    ) -> Float {
        let sourceChannel = min(channel, inputBuffers.count - 1)
        guard let data = inputBuffers[sourceChannel].mData else { return 0 }
        return readSample(data: data, frame: frame, channel: 0, bytesPerInputFrame: bytesPerFrame)
    }

    private func readSample(
        data: UnsafeMutableRawPointer,
        frame: Int,
        channel: Int,
        bytesPerInputFrame: Int
    ) -> Float {
        let offset = (frame * bytesPerInputFrame) + (channel * bytesPerSample)
        let pointer = UnsafeRawPointer(data).advanced(by: offset)

        switch sampleFormat {
        case .float32:
            return pointer.assumingMemoryBound(to: Float.self).pointee
        case .float64:
            return Float(pointer.assumingMemoryBound(to: Double.self).pointee)
        case .signedInteger(let bitDepth):
            return readSignedIntegerSample(pointer: pointer, bitDepth: bitDepth)
        case .unsupported:
            return 0
        }
    }

    private func readSignedIntegerSample(pointer: UnsafeRawPointer, bitDepth: Int) -> Float {
        let byteCount = min(bytesPerSample, 4)
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        var rawValue: UInt32 = 0

        for byteIndex in 0..<byteCount {
            let sourceIndex = isBigEndian ? byteIndex : byteCount - 1 - byteIndex
            rawValue = (rawValue << 8) | UInt32(bytes[sourceIndex])
        }

        let validBits = min(max(bitDepth, 1), 32)
        let mask = validBits == 32 ? UInt32.max : (UInt32(1) << UInt32(validBits)) - 1
        let signBit = UInt32(1) << UInt32(validBits - 1)
        let maskedValue = rawValue & mask
        let signedValue: Int32

        if validBits < 32 && (maskedValue & signBit) != 0 {
            signedValue = Int32(bitPattern: maskedValue | ~mask)
        } else {
            signedValue = Int32(bitPattern: maskedValue)
        }

        let denominator = Float(Int64(1) << (validBits - 1))
        return min(1, max(-1, Float(signedValue) / denominator))
    }
}

private enum InputSampleFormat: Equatable {
    case float32
    case float64
    case signedInteger(bitDepth: Int)
    case unsupported

    init(format: AudioStreamBasicDescription) {
        guard format.mFormatID == kAudioFormatLinearPCM else {
            self = .unsupported
            return
        }

        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitDepth = Int(format.mBitsPerChannel)

        if isFloat && bitDepth == 32 {
            self = .float32
        } else if isFloat && bitDepth == 64 {
            self = .float64
        } else if isSignedInteger {
            self = .signedInteger(bitDepth: bitDepth)
        } else {
            self = .unsupported
        }
    }
}
