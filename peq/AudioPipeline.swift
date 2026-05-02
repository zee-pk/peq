import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum AudioRuntimeError: LocalizedError {
    case coreAudio(String, OSStatus)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let message, let status):
            "\(message) (\(status))"
        case .engine(let message):
            message
        }
    }
}

final class AudioPipeline {
    private let tapManager = AudioTapManager()
    private let levelMeter: AudioLevelMeter
    private let healthStore: AudioHealthStore

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var eqController: EQController?
    private var renderContext: AudioRenderContext?
    private var ioProcID: AudioDeviceIOProcID?
    private var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var settings = EQSettings.flat
    private var restartWorkItem: DispatchWorkItem?

    init(levelMeter: AudioLevelMeter, healthStore: AudioHealthStore) {
        self.levelMeter = levelMeter
        self.healthStore = healthStore
    }

    var isRunning: Bool {
        engine?.isRunning == true
    }

    func start(settings: EQSettings) throws {
        try start(settings: settings, initialFadeGain: 1)
    }

    func stop() {
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }

        if let engine {
            engine.stop()
            engine.reset()
        }

        engine = nil
        sourceNode = nil
        eqController = nil
        renderContext = nil
        ioProcID = nil
        aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        tapManager.stop()
    }

    func apply(_ settings: EQSettings) {
        let sanitizedSettings = settings.sanitized()
        self.settings = sanitizedSettings
        healthStore.setEffectivePreampDb(GainStage.effectivePreampDb(for: sanitizedSettings))
        eqController?.apply(sanitizedSettings)
    }

    func healthSnapshot() -> AudioHealthSnapshot {
        healthStore.snapshot()
    }

    func scheduleRestart(
        reason: AudioDeviceChangeReason,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        restartWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }

            self.fade(to: 0, duration: 0.08)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }

                do {
                    try self.start(settings: self.settings, initialFadeGain: 0)
                    self.fade(to: 1, duration: 0.08)
                    onComplete(.success(()))
                } catch {
                    onComplete(.failure(error))
                }
            }
        }

        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + reason.coalescingDelay, execute: item)
    }

    private func start(settings: EQSettings, initialFadeGain: Float) throws {
        self.settings = settings.sanitized()
        stop()

        do {
            try startAudioPath(settings: self.settings, initialFadeGain: initialFadeGain)
        } catch {
            stop()
            throw error
        }
    }

    private func startAudioPath(settings: EQSettings, initialFadeGain: Float) throws {
        let aggregateInputDevice = try tapManager.start()
        aggregateDeviceID = aggregateInputDevice

        let tapFormatDescription = tapManager.tapFormat
        logTapFormat(tapFormatDescription)

        let engineFormat = try makeEngineFormat(from: tapFormatDescription)
        let renderContext = try AudioRenderContext(
            tapFormat: tapFormatDescription,
            maxFrameCount: 4096,
            healthStore: healthStore
        )
        renderContext.setFadeGain(initialFadeGain)

        let engine = AVAudioEngine()
        let eqController = EQController(settings: settings)
        let eqUnit = eqController.unit
        let sourceNode = AVAudioSourceNode(format: engineFormat) { [renderContext] isSilence, _, frameCount, outputData in
            renderContext.renderOutput(isSilence: isSilence, frameCount: frameCount, outputData: outputData)
        }

        engine.attach(sourceNode)
        engine.attach(eqUnit)
        engine.connect(sourceNode, to: eqUnit, format: engineFormat)
        engine.connect(eqUnit, to: engine.mainMixerNode, format: engineFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [levelMeter] buffer, _ in
            levelMeter.process(buffer)
        }

        engine.prepare()

        let ioProcID = try startCapture(deviceID: aggregateInputDevice, renderContext: renderContext)

        self.engine = engine
        self.sourceNode = sourceNode
        self.eqController = eqController
        self.renderContext = renderContext
        self.ioProcID = ioProcID

        try engine.start()

        updateOutputHealth(from: engine)
        healthStore.setEffectivePreampDb(GainStage.effectivePreampDb(for: settings))
        healthStore.incrementRebuildCount()
        logDiagnostics(after: 2)
    }

    private func makeEngineFormat(from streamDescription: AudioStreamBasicDescription) throws -> AVAudioFormat {
        let sampleRate = streamDescription.mSampleRate > 0 ? streamDescription.mSampleRate : 48_000
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioRuntimeError.engine("Unable to create stereo Float32 engine format")
        }

        return format
    }

    private func startCapture(
        deviceID: AudioDeviceID,
        renderContext: AudioRenderContext
    ) throws -> AudioDeviceIOProcID {
        var ioProcID: AudioDeviceIOProcID?

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, inputData, _, _, _ in
            renderContext.writeInput(inputData)
        }
        guard status == noErr else {
            throw AudioRuntimeError.coreAudio("Unable to create tap capture IOProc", status)
        }

        guard let ioProcID else {
            throw AudioRuntimeError.engine("Core Audio did not return a tap capture IOProc")
        }

        let startStatus = AudioDeviceStart(deviceID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            throw AudioRuntimeError.coreAudio("Unable to start tap capture device", startStatus)
        }

        return ioProcID
    }

    private func fade(to targetGain: Float, duration: TimeInterval) {
        guard let renderContext else { return }

        let steps = 8
        let startGain = renderContext.currentFadeGain()

        for step in 1...steps {
            let amount = Float(step) / Float(steps)
            let gain = startGain + ((targetGain - startGain) * amount)
            DispatchQueue.main.asyncAfter(deadline: .now() + (duration / Double(steps)) * Double(step)) {
                renderContext.setFadeGain(gain)
            }
        }
    }

    private func updateOutputHealth(from engine: AVAudioEngine) {
        let format = engine.outputNode.outputFormat(forBus: 0)
        healthStore.setOutputFormat(
            sampleRate: format.sampleRate,
            bitDepth: bitDepth(for: format)
        )
    }

    private func bitDepth(for format: AVAudioFormat) -> Int {
        switch format.commonFormat {
        case .pcmFormatFloat32:
            32
        case .pcmFormatFloat64:
            64
        case .pcmFormatInt16:
            16
        case .pcmFormatInt32:
            32
        default:
            0
        }
    }

    private func logTapFormat(_ streamDescription: AudioStreamBasicDescription) {
        NSLog(
            "peq tap format sampleRate=\(streamDescription.mSampleRate) channels=\(streamDescription.mChannelsPerFrame) formatID=\(streamDescription.mFormatID) flags=\(streamDescription.mFormatFlags) bytesPerFrame=\(streamDescription.mBytesPerFrame) framesPerPacket=\(streamDescription.mFramesPerPacket) bytesPerPacket=\(streamDescription.mBytesPerPacket) bitsPerChannel=\(streamDescription.mBitsPerChannel)"
        )
    }

    private func logDiagnostics(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            let health = self.healthSnapshot()
            NSLog(
                "peq audio health fill=\(health.bufferFillFrames) written=\(health.writtenFrames) rendered=\(health.renderedFrames) underruns=\(health.underruns) dropped=\(health.droppedFrames) trimmed=\(health.trimmedFrames) tap=\(health.tapSampleRate)/\(health.tapBitDepth) output=\(health.outputSampleRate)/\(health.outputBitDepth) capturedPeak=\(health.capturedPeak) outputPeak=\(health.outputPeak) effectivePreamp=\(health.effectivePreampDb)"
            )
        }
    }
}
