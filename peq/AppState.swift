import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var isClipping = false
    @Published private(set) var statusText = "Stopped"
    @Published private(set) var hasError = false
    @Published private(set) var audioHealth = AudioHealthSnapshot.empty
    @Published var settings: EQSettings

    private let presetStore = PresetStore()
    private let deviceManager = DeviceManager()
    private let healthStore = AudioHealthStore()
    private lazy var levelMeter = AudioLevelMeter(healthStore: healthStore)
    private lazy var audioPipeline = AudioPipeline(levelMeter: levelMeter, healthStore: healthStore)
    private var levelTimer: Timer?
    private var isRebuildingAudioPath = false

    init() {
        self.settings = presetStore.load()
    }

    func startMonitoring() {
        let shouldProcess = UserDefaults.standard.bool(forKey: "peq.isProcessing")
        
        deviceManager.start { [weak self] reason in
            DispatchQueue.main.async {
                self?.handleDeviceChange(reason: reason)
            }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDeviceChange(reason: .wakeRecovery)
            }
        }

        if levelTimer == nil {
            levelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let peak = self.levelMeter.currentPeak
                    self.audioHealth = self.audioPipeline.healthSnapshot()
                    self.isClipping = peak >= 1.0
                }
            }
        }
        
        if shouldProcess {
            setProcessing(true)
        }
    }

    func setProcessing(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "peq.isProcessing")
        if enabled {
            do {
                try audioPipeline.start(settings: settings)
                isProcessing = true
                hasError = false
                statusText = "EQ audio path enabled"
            } catch {
                isProcessing = false
                hasError = true
                statusText = error.localizedDescription
            }
        } else {
            audioPipeline.stop()
            isProcessing = false
            isClipping = false
            hasError = false
            statusText = "Stopped"
        }
    }

    func setBypass(_ bypass: Bool) {
        settings.bypass = bypass
        persistAndApply()
    }

    func setOutputGain(_ gainDb: Double) {
        settings.outputGainDb = EQLimits.clamp(gainDb, to: EQLimits.outputGainDb)
        persistAndApply()
    }

    func updateBand(_ band: EQBand) {
        guard let index = settings.bands.firstIndex(where: { $0.id == band.id }) else {
            return
        }

        var sanitizedBand = band
        sanitizedBand.frequencyHz = EQLimits.clamp(sanitizedBand.frequencyHz, to: EQLimits.frequencyHz)
        sanitizedBand.gainDb = EQLimits.clamp(sanitizedBand.gainDb, to: EQLimits.bandGainDb)
        sanitizedBand.bandwidth = EQLimits.clamp(sanitizedBand.bandwidth, to: EQLimits.bandwidth)
        settings.bands[index] = sanitizedBand
        persistAndApply()
    }

    func addBand() {
        settings.bands.append(EQSettings.newBand(number: settings.bands.count + 1))
        persistAndRebuildIfNeeded()
    }

    func removeBand(_ band: EQBand) {
        guard settings.bands.count > 1 else { return }
        settings.bands.removeAll { $0.id == band.id }
        renumberBands()
        persistAndRebuildIfNeeded()
    }

    func resetDefaults() {
        settings = .flat
        persistAndRebuildIfNeeded()
    }

    private func persistAndApply() {
        presetStore.save(settings)
        audioPipeline.apply(settings)
    }

    private func persistAndRebuildIfNeeded() {
        presetStore.save(settings)

        guard isProcessing else {
            audioPipeline.apply(settings)
            return
        }

        do {
            statusText = "Rebuilding audio path"
            try audioPipeline.start(settings: settings)
            hasError = false
            statusText = "EQ audio path enabled"
        } catch {
            isProcessing = false
            hasError = true
            statusText = error.localizedDescription
        }
    }

    private func renumberBands() {
        for index in settings.bands.indices {
            settings.bands[index].name = "Band \(index + 1)"
        }
    }

    private func handleDeviceChange(reason: AudioDeviceChangeReason) {
        guard isProcessing, !isRebuildingAudioPath else { return }

        isRebuildingAudioPath = true
        statusText = "\(reason.statusText); rebuilding audio path"
        audioPipeline.scheduleRestart(reason: reason) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }

                self.isRebuildingAudioPath = false

                switch result {
                case .success:
                    self.isProcessing = true
                    self.hasError = false
                    self.statusText = "EQ audio path enabled"
                case .failure(let error):
                    self.isProcessing = false
                    self.hasError = true
                    self.statusText = error.localizedDescription
                }
            }
        }
    }
}
